use super::{Error, Result};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};
use rand::{CryptoRng, RngCore};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use sha2::{Digest, Sha256};

const MAX_STATEMENT: usize = 16 * 1024;
const DEFAULT_REUSABLE_LIFETIME: i64 = 30 * 86_400;
const MAX_SINGLE_USE_LIFETIME: i64 = 30 * 60;

pub trait Statement: DeserializeOwned + Serialize {
    const PURPOSE: &'static str;
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Signed {
    statement: String,
    signature: String,
}

impl Signed {
    pub fn sign<T: Statement>(key: &SigningKey, statement: &T) -> Result<Self> {
        let statement = canonical(statement)?;
        let message = message::<T>(&statement)?;
        Ok(Self {
            statement: URL_SAFE_NO_PAD.encode(statement),
            signature: URL_SAFE_NO_PAD.encode(key.sign(&message).to_bytes()),
        })
    }

    pub fn read<T: Statement>(&self) -> Result<T> {
        decode_statement(&self.statement_bytes()?)
    }

    pub fn verify<T: Statement>(&self, key: &VerifyingKey) -> Result<T> {
        let statement = self.statement_bytes()?;
        let signature = Signature::from_bytes(&decode(&self.signature)?);
        key.verify_strict(&message::<T>(&statement)?, &signature)
            .map_err(|_| Error::InvalidSignature)?;
        decode_statement(&statement)
    }

    pub fn digest<T: Statement>(&self) -> Result<String> {
        Ok(hex::encode(Sha256::digest(message::<T>(
            &self.statement_bytes()?,
        )?)))
    }

    fn statement_bytes(&self) -> Result<Vec<u8>> {
        if self.statement.len() > MAX_STATEMENT.div_ceil(3) * 4 {
            return Err(Error::InvalidArtifact);
        }
        let bytes = URL_SAFE_NO_PAD
            .decode(&self.statement)
            .map_err(|_| Error::InvalidArtifact)?;
        if URL_SAFE_NO_PAD.encode(&bytes) != self.statement {
            return Err(Error::InvalidArtifact);
        }
        Ok(bytes)
    }
}

fn canonical<T: Serialize>(statement: &T) -> Result<Vec<u8>> {
    // serde_json's maps sort object keys. Both native implementations reject signed JSON
    // whose exact bytes differ from the canonical representation of the typed statement.
    let mut value = serde_json::to_value(statement).map_err(|_| Error::InvalidArtifact)?;
    value.sort_all_objects();
    serde_json::to_vec(&value).map_err(|_| Error::InvalidArtifact)
}

fn decode_statement<T: Statement>(bytes: &[u8]) -> Result<T> {
    let statement = serde_json::from_slice(bytes).map_err(|_| Error::InvalidArtifact)?;
    if canonical(&statement)? != bytes {
        return Err(Error::InvalidArtifact);
    }
    Ok(statement)
}

fn message<T: Statement>(statement: &[u8]) -> Result<Vec<u8>> {
    if statement.len() > MAX_STATEMENT {
        return Err(Error::InvalidArtifact);
    }
    let mut message = format!("myterm-account-v1:{}\0", T::PURPOSE).into_bytes();
    message.extend_from_slice(statement);
    Ok(message)
}

pub(super) fn decode<const LENGTH: usize>(text: &str) -> Result<[u8; LENGTH]> {
    if text.len() > LENGTH.div_ceil(3) * 4 {
        return Err(Error::InvalidArtifact);
    }
    let mut bytes = [0; LENGTH];
    if URL_SAFE_NO_PAD.decode_slice(text, &mut bytes).ok() != Some(LENGTH)
        || URL_SAFE_NO_PAD.encode(bytes) != text
    {
        return Err(Error::InvalidArtifact);
    }
    Ok(bytes)
}

pub fn valid_id(value: &str, size: usize) -> bool {
    value.len() == size
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct SigningIdentity(String);

impl SigningIdentity {
    pub fn from_key(key: &SigningKey) -> Self {
        Self(URL_SAFE_NO_PAD.encode(key.verifying_key().as_bytes()))
    }

    pub fn key(&self) -> Result<VerifyingKey> {
        let bytes = decode(&self.0)?;
        let key = VerifyingKey::from_bytes(&bytes).map_err(|_| Error::InvalidArtifact)?;
        let point = key.to_edwards();
        if key.is_weak() || !point.is_torsion_free() || point.compress().to_bytes() != bytes {
            return Err(Error::InvalidArtifact);
        }
        Ok(key)
    }

    pub fn id(&self) -> Result<String> {
        Ok(hex::encode(Sha256::digest(self.key()?.as_bytes())))
    }
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct AccountGenesis {
    nonce: String,
    pub first_client: SigningIdentity,
    pub authority: SigningIdentity,
}

impl Statement for AccountGenesis {
    const PURPOSE: &'static str = "genesis";
}

impl AccountGenesis {
    pub fn new(
        first_client: &SigningKey,
        authority: &SigningKey,
        rng: &mut (impl CryptoRng + RngCore),
    ) -> Self {
        let mut nonce = [0; 32];
        rng.fill_bytes(&mut nonce);
        Self {
            nonce: URL_SAFE_NO_PAD.encode(nonce),
            first_client: SigningIdentity::from_key(first_client),
            authority: SigningIdentity::from_key(authority),
        }
    }

    pub fn anchor(genesis: &Signed) -> Result<String> {
        let untrusted: Self = genesis.read()?;
        let verified: Self = genesis.verify(&untrusted.first_client.key()?)?;
        let _: [u8; 32] = decode(&verified.nonce)?;
        verified.authority.key()?;
        if verified.first_client == verified.authority {
            return Err(Error::InvalidArtifact);
        }
        genesis.digest::<Self>()
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum CredentialMode {
    SingleUse,
    Reusable,
}

impl CredentialMode {
    pub(super) fn lifetime(self, requested: Option<i64>) -> Result<i64> {
        let lifetime = requested.unwrap_or(match self {
            Self::SingleUse => MAX_SINGLE_USE_LIFETIME,
            Self::Reusable => DEFAULT_REUSABLE_LIFETIME,
        });
        if lifetime <= 0 || (self == Self::SingleUse && lifetime > MAX_SINGLE_USE_LIFETIME) {
            return Err(Error::InvalidCredential);
        }
        Ok(lifetime)
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct IssueCredential {
    pub account: String,
    pub operation: String,
    pub creator: SigningIdentity,
    pub holder: SigningIdentity,
    pub mode: CredentialMode,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub lifetime_seconds: Option<i64>,
}

impl Statement for IssueCredential {
    const PURPOSE: &'static str = "issue-enrollment-credential";
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Credential {
    pub account: String,
    pub id: String,
    pub creator: SigningIdentity,
    pub holder: SigningIdentity,
    pub mode: CredentialMode,
    pub issued_at: i64,
    pub expires_at: i64,
}

impl Statement for Credential {
    const PURPOSE: &'static str = "server-enrollment-credential";
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CredentialStatus {
    Active,
    ExpiresWithinSevenDays,
    ExpiresWithinOneDay,
    Expired,
}

impl Credential {
    pub fn verify(signed: &Signed, anchor: &str, authority: &VerifyingKey) -> Result<Self> {
        let credential: Self = signed.verify(authority)?;
        if credential.account != anchor {
            return Err(Error::WrongAccount);
        }
        if !valid_id(&credential.id, 64) || credential.issued_at <= 0 {
            return Err(Error::InvalidCredential);
        }
        credential.holder.key()?;
        credential.creator.key()?;
        credential
            .mode
            .lifetime(credential.expires_at.checked_sub(credential.issued_at))?;
        if credential.expires_at <= credential.issued_at {
            return Err(Error::InvalidCredential);
        }
        Ok(credential)
    }

    pub fn status(&self, now: i64) -> CredentialStatus {
        match self.expires_at.saturating_sub(now) {
            ..=0 => CredentialStatus::Expired,
            1..=86_400 => CredentialStatus::ExpiresWithinOneDay,
            86_401..=604_800 => CredentialStatus::ExpiresWithinSevenDays,
            _ => CredentialStatus::Active,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct EnrollmentRequest {
    pub account: String,
    pub credential: String,
    pub server: SigningIdentity,
    pub name: String,
    pub relay_access: bool,
}

impl Statement for EnrollmentRequest {
    const PURPOSE: &'static str = "server-enrollment-request";
}

impl EnrollmentRequest {
    pub fn new(
        account: String,
        credential: &Signed,
        authority: &VerifyingKey,
        server: &SigningKey,
        name: String,
        relay_access: bool,
    ) -> Result<Self> {
        let credential = Credential::verify(credential, &account, authority)?;
        let request = Self {
            account,
            credential: credential.id,
            server: SigningIdentity::from_key(server),
            name,
            relay_access,
        };
        request.validate()?;
        Ok(request)
    }

    pub fn verify(signed: &Signed, anchor: &str) -> Result<Self> {
        let untrusted: Self = signed.read()?;
        let request: Self = signed.verify(&untrusted.server.key()?)?;
        if request.account != anchor {
            return Err(Error::WrongAccount);
        }
        request.validate()?;
        Ok(request)
    }

    fn validate(&self) -> Result<()> {
        if !valid_id(&self.credential, 64) {
            return Err(Error::InvalidArtifact);
        }
        Self::validate_name(&self.name)
    }

    pub(super) fn validate_name(name: &str) -> Result<()> {
        if name.trim().is_empty() || name.len() > 160 || name.chars().any(char::is_control) {
            return Err(Error::InvalidArtifact);
        }
        Ok(())
    }
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct HolderProof {
    pub enrollment_digest: String,
}

impl Statement for HolderProof {
    const PURPOSE: &'static str = "server-enrollment-holder-proof";
}

impl HolderProof {
    pub fn new(request: &Signed) -> Result<Self> {
        Ok(Self {
            enrollment_digest: request.digest::<EnrollmentRequest>()?,
        })
    }

    pub fn verify(signed: &Signed, request: &Signed, credential: &Credential) -> Result<()> {
        let proof: Self = signed.verify(&credential.holder.key()?)?;
        if proof.enrollment_digest != Self::new(request)?.enrollment_digest {
            return Err(Error::InvalidCredential);
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Admission {
    pub request: EnrollmentRequest,
    pub enrollment_digest: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub confirmed_by: Option<SigningIdentity>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct ManagementRequest {
    pub account: String,
    pub operation: String,
    pub actor: SigningIdentity,
    pub change: MembershipOperation,
}

impl Statement for ManagementRequest {
    const PURPOSE: &'static str = "manage-server-enrollment";
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(
    deny_unknown_fields,
    tag = "kind",
    content = "value",
    rename_all = "kebab-case"
)]
pub enum MembershipOperation {
    Issue(Credential),
    Admit(Admission),
    RevokeCredential(String),
    RemoveIdentity(SigningIdentity),
    FreshApprove(Signed),
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct MembershipEvent {
    pub account: String,
    pub sequence: i64,
    pub previous: String,
    pub change: MembershipOperation,
}

impl Statement for MembershipEvent {
    const PURPOSE: &'static str = "membership-event";
}
