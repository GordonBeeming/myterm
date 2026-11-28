use super::storage::{install_json, prepare_state_directory, read_bounded, read_json, signing_key};
use super::{
    AccountGenesis, Authority, Credential, CredentialStatus, EnrollmentRequest, Error, HolderProof,
    Result, Signed, SigningIdentity,
};
use ed25519_dalek::SigningKey;
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use std::io::{self, Write};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};
use zeroize::Zeroizing;

const MAX_INPUT: u64 = 96 * 1024;

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct AccountBinding {
    anchor: String,
    genesis: Signed,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields, tag = "operation", rename_all = "kebab-case")]
enum AuthorityRequest {
    Issue {
        request: Signed,
    },
    Manage {
        request: Signed,
    },
    Redeem {
        presentation: EnrollmentPresentation,
    },
    Events {
        after: i64,
    },
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct EnrollmentPresentation {
    pub credential: Signed,
    pub request: Signed,
    pub possession: Signed,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct ProvisioningInput {
    binding: AccountBinding,
    pinned_anchor: String,
    credential: Signed,
    name: String,
    #[serde(default)]
    relay_access: bool,
    holder_seed: Secret,
}

#[derive(Deserialize)]
#[serde(transparent)]
struct Secret(String);

impl Drop for Secret {
    fn drop(&mut self) {
        use zeroize::Zeroize;
        self.0.zeroize();
    }
}

#[derive(Serialize)]
#[serde(rename_all = "kebab-case")]
enum ExpiryWarning {
    Active,
    ExpiresWithinSevenDays,
    ExpiresWithinOneDay,
    Expired,
}

impl From<CredentialStatus> for ExpiryWarning {
    fn from(status: CredentialStatus) -> Self {
        match status {
            CredentialStatus::Active => Self::Active,
            CredentialStatus::ExpiresWithinSevenDays => Self::ExpiresWithinSevenDays,
            CredentialStatus::ExpiresWithinOneDay => Self::ExpiresWithinOneDay,
            CredentialStatus::Expired => Self::Expired,
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ProvisioningStatus {
    server: SigningIdentity,
    expiry_warning: ExpiryWarning,
    presentation: EnrollmentPresentation,
}

/// Each invocation handles one bounded local request. Only trusted local launchers may pass
/// provisioning inputs or authority state paths to this command.
pub fn run(operation: &str, directory: &Path) -> Result<()> {
    match operation {
        "authority-identity" => {
            prepare_state_directory(directory)?;
            output(&SigningIdentity::from_key(&signing_key(
                &directory.join("authority-signing.key"),
                true,
            )?))
        }
        "account-binding" => {
            prepare_state_directory(directory)?;
            let committed = existing_binding(&directory.join("account.json"))?;
            let binding = match committed {
                Some(binding) => Some(binding),
                None => existing_binding(&directory.join("pending-account.json"))?,
            };
            output(&binding)
        }
        "configure-authority" => output(&configure_authority(input()?, directory)?),
        "authority-request" => {
            let request = input()?;
            prepare_state_directory(directory)?;
            let binding: AccountBinding = read_json(&directory.join("account.json"), MAX_INPUT)?;
            let signer = signing_key(&directory.join("authority-signing.key"), false)?;
            let mut authority = Authority::reopen(
                &directory.join("authority"),
                &binding.genesis,
                binding.anchor,
                &signer,
            )?;
            match request {
                AuthorityRequest::Issue { request } => output(&authority.issue(&request)?),
                AuthorityRequest::Manage { request } => output(&authority.manage(&request)?),
                AuthorityRequest::Redeem { presentation } => output(&authority.redeem(
                    &presentation.credential,
                    &presentation.request,
                    &presentation.possession,
                )?),
                AuthorityRequest::Events { after } => output(&authority.events_after(after)?),
            }
        }
        "prepare-server" => output(&prepare_server(input()?, directory)?),
        "provisioning-status" => {
            prepare_state_directory(directory)?;
            let binding: AccountBinding =
                read_json(&directory.join("provisioned-account.json"), MAX_INPUT)?;
            let presentation: EnrollmentPresentation =
                read_json(&directory.join("prepared-server.json"), MAX_INPUT)?;
            let (credential, request) = validate_presentation(&binding, &presentation)?;
            let signer = signing_key(&directory.join("server-signing.key"), false)?;
            if SigningIdentity::from_key(&signer) != request.server {
                return Err(Error::IdentityConflict);
            }
            output(&ProvisioningStatus {
                server: request.server,
                expiry_warning: credential.status(now()?).into(),
                presentation,
            })
        }
        _ => Err(Error::InvalidArtifact),
    }
}

fn configure_authority(binding: AccountBinding, directory: &Path) -> Result<String> {
    prepare_state_directory(directory)?;
    let signer = signing_key(&directory.join("authority-signing.key"), false)?;
    if AccountGenesis::anchor(&binding.genesis)? != binding.anchor {
        return Err(Error::WrongAccount);
    }
    let genesis: AccountGenesis = binding.genesis.read()?;
    if genesis.authority != SigningIdentity::from_key(&signer) {
        return Err(Error::UntrustedEndpoint);
    }
    let committed = directory.join("account.json");
    let database = directory.join("authority");
    if let Some(existing) = existing_binding(&committed)? {
        if existing.anchor != binding.anchor {
            return Err(Error::WrongAccount);
        }
        Authority::reopen(&database, &binding.genesis, binding.anchor.clone(), &signer)?;
    } else {
        // Keep the original genesis available if startup ends before the account commits.
        install_binding(&directory.join("pending-account.json"), &binding)?;
        Authority::open(&database, &binding.genesis, binding.anchor.clone(), &signer)?;
        install_binding(&committed, &binding)?;
    }
    Ok(binding.anchor)
}

fn existing_binding(path: &Path) -> Result<Option<AccountBinding>> {
    match read_json(path, MAX_INPUT) {
        Ok(binding) => Ok(Some(binding)),
        Err(Error::Io(error)) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error),
    }
}

fn install_binding(path: &Path, binding: &AccountBinding) -> Result<()> {
    match install_json(path, binding) {
        Err(Error::Io(error)) if error.kind() == io::ErrorKind::AlreadyExists => {
            let existing: AccountBinding = read_json(path, MAX_INPUT)?;
            if existing.anchor != binding.anchor {
                return Err(Error::WrongAccount);
            }
            Ok(())
        }
        result => result,
    }
}

fn prepare_server(input: ProvisioningInput, directory: &Path) -> Result<ProvisioningStatus> {
    if input.binding.anchor != input.pinned_anchor
        || AccountGenesis::anchor(&input.binding.genesis)? != input.pinned_anchor
    {
        return Err(Error::WrongAccount);
    }
    let genesis: AccountGenesis = input.binding.genesis.read()?;
    let authority = genesis.authority.key()?;
    let credential = Credential::verify(&input.credential, &input.binding.anchor, &authority)?;
    let seed = Zeroizing::new(super::statements::decode::<32>(&input.holder_seed.0)?);
    let holder = SigningKey::from_bytes(&seed);
    if SigningIdentity::from_key(&holder) != credential.holder {
        return Err(Error::InvalidCredential);
    }
    EnrollmentRequest::validate_name(&input.name)?;
    prepare_state_directory(directory)?;
    let server_path = directory.join("prepared-server.json");
    let binding_path = directory.join("provisioned-account.json");
    let signer_path = directory.join("server-signing.key");
    let now = now()?;
    match read_json::<EnrollmentPresentation>(&server_path, MAX_INPUT) {
        Ok(presentation) => {
            let binding: AccountBinding = read_json(&binding_path, MAX_INPUT)?;
            let (prior, request) = validate_presentation(&binding, &presentation)?;
            let server = signing_key(&signer_path, false)?;
            if prior != credential
                || request.server != SigningIdentity::from_key(&server)
                || request.name != input.name
                || request.relay_access != input.relay_access
            {
                return Err(Error::IdentityConflict);
            }
            return Ok(ProvisioningStatus {
                server: request.server,
                expiry_warning: prior.status(now).into(),
                presentation,
            });
        }
        Err(Error::Io(error)) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    if now < credential.issued_at || credential.status(now) == CredentialStatus::Expired {
        return Err(Error::FreshApprovalRequired);
    }

    install_binding(&binding_path, &input.binding)?;
    let server = signing_key(&signer_path, true)?;
    let request = EnrollmentRequest::new(
        input.binding.anchor,
        &input.credential,
        &authority,
        &server,
        input.name,
        input.relay_access,
    )?;
    let signed = Signed::sign(&server, &request)?;
    let proof = Signed::sign(&holder, &HolderProof::new(&signed)?)?;
    let presentation = EnrollmentPresentation {
        credential: input.credential,
        request: signed,
        possession: proof,
    };

    match install_json(&server_path, &presentation) {
        Err(Error::Io(error)) if error.kind() == io::ErrorKind::AlreadyExists => {
            // An overlapping launcher may finish the same operation before this one.
            let existing: EnrollmentPresentation = read_json(&server_path, MAX_INPUT)?;
            if existing.request != presentation.request {
                return Err(Error::IdentityConflict);
            }
        }
        result => result?,
    }

    Ok(ProvisioningStatus {
        server: request.server,
        expiry_warning: credential.status(now).into(),
        presentation,
    })
}

fn validate_presentation(
    binding: &AccountBinding,
    presentation: &EnrollmentPresentation,
) -> Result<(Credential, EnrollmentRequest)> {
    if AccountGenesis::anchor(&binding.genesis)? != binding.anchor {
        return Err(Error::WrongAccount);
    }
    let genesis: AccountGenesis = binding.genesis.read()?;
    let credential = Credential::verify(
        &presentation.credential,
        &binding.anchor,
        &genesis.authority.key()?,
    )?;
    let request = EnrollmentRequest::verify(&presentation.request, &binding.anchor)?;
    HolderProof::verify(&presentation.possession, &presentation.request, &credential)?;
    if request.credential != credential.id {
        return Err(Error::InvalidCredential);
    }
    Ok((credential, request))
}

fn now() -> Result<i64> {
    let elapsed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| Error::Clock)?;
    i64::try_from(elapsed.as_secs()).map_err(|_| Error::Clock)
}

fn input<T: DeserializeOwned>() -> Result<T> {
    let bytes = Zeroizing::new(read_bounded(io::stdin().lock(), MAX_INPUT)?);
    serde_json::from_slice(&bytes).map_err(|_| Error::InvalidArtifact)
}

fn output<T: Serialize>(value: &T) -> Result<()> {
    let mut output = io::stdout().lock();
    serde_json::to_writer(&mut output, value).map_err(|_| Error::InvalidArtifact)?;
    output.write_all(b"\n")?;
    output.flush()?;
    Ok(())
}
