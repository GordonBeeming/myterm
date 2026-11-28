mod authority;
pub mod command;
mod statements;
mod storage;

pub use authority::Authority;
pub use statements::{
    AccountGenesis, Admission, Credential, CredentialMode, CredentialStatus, EnrollmentRequest,
    HolderProof, IssueCredential, ManagementRequest, MembershipEvent, MembershipOperation, Signed,
    SigningIdentity,
};

#[derive(Debug)]
pub enum Error {
    InvalidArtifact,
    WrongAccount,
    InvalidSignature,
    UntrustedEndpoint,
    InvalidCredential,
    CredentialConsumed,
    FreshApprovalRequired,
    IdentityConflict,
    IdentityRemoved,
    AdmissionLimited,
    UnsafeStateDirectory,
    Store(rusqlite::Error),
    Io(std::io::Error),
    Clock,
}

impl std::fmt::Display for Error {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let description = match self {
            Self::InvalidArtifact => "Invalid enrollment artifact",
            Self::WrongAccount => "Enrollment account binding could not be verified",
            Self::InvalidSignature => "Enrollment signature could not be verified",
            Self::UntrustedEndpoint => "Enrollment operation requires a trusted endpoint",
            Self::InvalidCredential => "Invalid enrollment credential",
            Self::CredentialConsumed => "Single-use credential has already enrolled a server",
            Self::FreshApprovalRequired => "Server needs fresh approval from a trusted endpoint",
            Self::IdentityConflict => "An existing identity is bound to a different enrollment",
            Self::IdentityRemoved => "This server identity was removed from the account",
            Self::AdmissionLimited => "Deployment admission limit reached for this hour",
            Self::UnsafeStateDirectory => {
                "Enrollment state requires a private directory owned by this user"
            }
            Self::Store(_) => "Enrollment state could not be read or committed",
            Self::Io(_) => "Enrollment storage could not be accessed",
            Self::Clock => "Enrollment clock could not be read",
        };
        formatter.write_str(description)
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Store(error) => Some(error),
            Self::Io(error) => Some(error),
            _ => None,
        }
    }
}

impl From<rusqlite::Error> for Error {
    fn from(error: rusqlite::Error) -> Self {
        Self::Store(error)
    }
}

impl From<std::io::Error> for Error {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error)
    }
}

pub type Result<T> = std::result::Result<T, Error>;
