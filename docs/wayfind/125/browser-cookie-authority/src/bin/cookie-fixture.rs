use myterm_browser_cookie_authority_probe::{ApprovedClientScope, Authority, Change, Scope};
use std::{env, path::Path};

const KEY: [u8; 32] = [3; 32];
const COOKIE: &str = "localhost / myterm_profile";

fn main() {
    if let Err(message) = run(&env::args().skip(1).collect::<Vec<_>>()) {
        eprintln!("Cookie fixture: {message}");
        std::process::exit(1);
    }
}

fn run(arguments: &[String]) -> Result<(), String> {
    let [operation, file, profile, ..] = arguments else {
        return Err(
            "usage: cookie-fixture write FILE PROFILE myterm_profile=B | read FILE PROFILE".into(),
        );
    };
    let scope = Scope {
        account: "fixture-account".into(),
        server: "fixture-server-b".into(),
        profile: profile.clone(),
    };
    let permit = ApprovedClientScope(scope.clone());
    let path = Path::new(file);
    match (operation.as_str(), arguments.get(3)) {
        ("write", Some(observation)) if observation == "myterm_profile=B" => {
            let mut authority =
                Authority::create(scope, path, &KEY).map_err(|error| format!("{error:?}"))?;
            authority
                .apply(
                    &permit,
                    0,
                    vec![Change {
                        cookie_key: COOKIE.into(),
                        previous_version: None,
                        value: Some("B".into()),
                    }],
                )
                .map_err(|error| format!("{error:?}"))
        }
        ("read", None) => {
            let authority =
                Authority::open(scope, path, &KEY).map_err(|error| format!("{error:?}"))?;
            let snapshot = authority
                .snapshot(&permit)
                .map_err(|error| format!("{error:?}"))?;
            let value = snapshot
                .entries
                .get(COOKIE)
                .and_then(|entry| entry.value.as_deref())
                .ok_or("fixture cookie missing")?;
            println!("{value}");
            Ok(())
        }
        _ => Err("the fixture handles only its generated cookie".into()),
    }
}
