//! Disposable local route fixture. It forwards only the two forms of one generated origin.

mod observer;

use bytes::Bytes;
use h2::{server, RecvStream, SendStream};
use http::{Method, Request, Response, StatusCode};
use rustls_pki_types::{pem::PemObject, CertificateDer, PrivateKeyDer};
use std::{
    env,
    future::poll_fn,
    io,
    net::{IpAddr, SocketAddr},
    path::PathBuf,
    sync::Arc,
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    sync::watch,
    time::{sleep, timeout},
};
use tokio_rustls::{rustls, TlsAcceptor};

type Error = Box<dyn std::error::Error + Send + Sync>;
const DEADLINE: Duration = Duration::from_secs(8);

struct Target {
    hostname: String,
    address: IpAddr,
    port: u16,
    admission: Option<String>,
    control_admission: Option<String>,
    revoked: watch::Receiver<bool>,
    loopback_alias: bool,
    authority_port: u16,
}

#[tokio::main]
async fn main() -> Result<(), Error> {
    let arguments: Vec<String> = env::args().skip(1).collect();
    match arguments.as_slice() {
        [mode, address, expected_peer] if mode == "origin" => {
            run_origin(address, expected_peer.parse()?).await
        }
        [mode, address, hostname, origin_ip, origin_port, certificate, key] if mode == "proxy" => {
            let (revocation, revoked) = watch::channel(false);
            if let Some(path) = env::var_os("MYTERM_FIXTURE_REVOCATION_FILE") {
                let revocation = revocation.clone();
                tokio::spawn(announce_revocation(path.into(), revocation));
            }
            let target_port = origin_port.parse()?;
            let loopback_alias = env::var_os("MYTERM_FIXTURE_LOOPBACK_ALIAS").is_some();
            let target = Target {
                hostname: hostname.clone(),
                address: origin_ip.parse()?,
                port: target_port,
                admission: env::var("MYTERM_FIXTURE_ADMISSION").ok(),
                control_admission: env::var("MYTERM_FIXTURE_CONTROL_ADMISSION").ok(),
                revoked,
                loopback_alias,
                authority_port: if loopback_alias { 443 } else { target_port },
            };
            if target.loopback_alias && !target.address.is_loopback() {
                return Err(
                    io::Error::other("alias fixture requires an assigned loopback target").into(),
                );
            }
            let result = run_proxy(address, target, certificate, key).await;
            drop(revocation);
            result
        }
        [mode, listen, next] if mode == "observe" => {
            let marker = env::var("MYTERM_FIXTURE_ADMISSION")?;
            observer::run(listen.parse()?, next.parse()?, &marker).await
        }
        _ => Err(io::Error::other(
            "use origin LISTEN PROXY_IP or proxy LISTEN DNS_NAME ORIGIN_IP ORIGIN_PORT CERT KEY",
        )
        .into()),
    }
}

async fn run_origin(listen: &str, expected: IpAddr) -> Result<(), Error> {
    let listener = TcpListener::bind(listen).await?;
    eprintln!("origin ready");
    loop {
        let (stream, peer) = listener.accept().await?;
        tokio::spawn(async move {
            match timeout(DEADLINE, respond_to_origin(stream, peer, expected)).await {
                Ok(Ok(())) => {}
                Ok(Err(error)) => eprintln!("Origin request failed: {error}"),
                Err(error) => eprintln!("Origin request expired: {error}"),
            }
        });
    }
}

async fn respond_to_origin(
    mut stream: TcpStream,
    peer: SocketAddr,
    expected: IpAddr,
) -> Result<(), Error> {
    let mut request = Vec::new();
    let mut chunk = [0; 1024];
    while !request.windows(4).any(|window| window == b"\r\n\r\n") {
        let length = stream.read(&mut chunk).await?;
        if length == 0 || request.len() + length > 8192 {
            return Err(io::Error::other("invalid fixture request").into());
        }
        request.extend_from_slice(&chunk[..length]);
    }
    let headers = std::str::from_utf8(&request)?;
    let leaked_admission = headers
        .lines()
        .filter_map(|line| line.split_once(':'))
        .any(|(name, _)| name.eq_ignore_ascii_case("x-myterm-fixture-admission"));
    let permitted = peer.ip() == expected && !leaked_admission;
    if permitted && headers.starts_with("GET /revocation-stream ") {
        stream_revocation_fixture(stream).await?;
        return Ok(());
    }
    let (status, marker) = if permitted {
        ("200 OK", "RUST_PRIVATE_ORIGIN")
    } else {
        ("403 Forbidden", "DIRECT_SOURCE_DENIED")
    };
    let body = format!("<!doctype html><title>{marker}</title>");
    let header = format!(
        "HTTP/1.1 {status}\r\nContent-Type: text/html\r\nContent-Length: {}\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n",
        body.len()
    );
    stream.write_all(header.as_bytes()).await?;
    stream.write_all(body.as_bytes()).await?;
    stream.shutdown().await?;
    eprintln!(
        "origin permitted={permitted} source={} received_admission_header={leaked_admission}",
        peer.ip()
    );
    Ok(())
}

async fn stream_revocation_fixture(mut stream: TcpStream) -> Result<(), Error> {
    stream.write_all(
        b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\nCache-Control: no-store\r\n\r\n",
    ).await?;
    for _ in 0..150 {
        stream.write_all(b"5\r\ntick\n\r\n").await?;
        sleep(Duration::from_millis(50)).await;
    }
    stream.write_all(b"0\r\n\r\n").await?;
    Ok(())
}

async fn announce_revocation(path: PathBuf, publisher: watch::Sender<bool>) {
    while !path.exists() {
        sleep(Duration::from_millis(20)).await;
    }
    publisher.send_replace(true);
    eprintln!("fixture admission revoked");
}

async fn wait_for_revocation(revocation: &mut Option<watch::Receiver<bool>>) {
    if let Some(revocation) = revocation {
        if revocation.wait_for(|committed| *committed).await.is_ok() {
            return;
        }
    }
    std::future::pending::<()>().await;
}

async fn run_proxy(listen: &str, target: Target, cert: &str, key: &str) -> Result<(), Error> {
    let certificates = CertificateDer::pem_file_iter(cert)?.collect::<Result<Vec<_>, _>>()?;
    let key = PrivateKeyDer::from_pem_file(key)?;
    let mut tls = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(certificates, key)?;
    tls.alpn_protocols = vec![b"h2".to_vec()];
    let acceptor = TlsAcceptor::from(Arc::new(tls));
    let target = Arc::new(target);
    let listener = TcpListener::bind(listen).await?;
    eprintln!("proxy ready");
    loop {
        let (stream, _) = listener.accept().await?;
        let acceptor = acceptor.clone();
        let target = Arc::clone(&target);
        tokio::spawn(async move {
            if let Err(error) = handle_connection(acceptor, stream, target).await {
                eprintln!("Proxy connection: {error}");
            }
        });
    }
}

async fn handle_connection(
    acceptor: TlsAcceptor,
    stream: TcpStream,
    target: Arc<Target>,
) -> Result<(), Error> {
    let tls = timeout(DEADLINE, acceptor.accept(stream)).await??;
    let mut h2 = timeout(DEADLINE, server::handshake(tls)).await??;
    while let Some(stream) = h2.accept().await {
        let (request, respond) = stream?;
        let target = Arc::clone(&target);
        tokio::spawn(async move {
            match timeout(DEADLINE, forward(request, respond, &target)).await {
                Ok(Ok(())) => {}
                Ok(Err(error)) => eprintln!("Proxy stream: {error}"),
                Err(error) => eprintln!("Proxy stream expired: {error}"),
            }
        });
    }
    Ok(())
}

async fn forward(
    request: Request<RecvStream>,
    mut respond: server::SendResponse<Bytes>,
    target: &Target,
) -> Result<(), Error> {
    let mut revocation = None;
    if let Some(expected) = &target.admission {
        let mut values = request
            .headers()
            .get_all("x-myterm-fixture-admission")
            .iter();
        let value = values.next().map(http::HeaderValue::as_bytes);
        let control = target
            .control_admission
            .as_ref()
            .is_some_and(|control| value == Some(control.as_bytes()));
        let matches = value == Some(expected.as_bytes());
        if (!matches && !control)
            || values.next().is_some()
            || (matches && *target.revoked.borrow())
        {
            eprintln!("CONNECT fixture denied admission");
            respond.send_response(
                Response::builder().status(StatusCode::FORBIDDEN).body(())?,
                true,
            )?;
            return Ok(());
        }
        if matches {
            revocation = Some(target.revoked.clone());
        }
        eprintln!("CONNECT fixture admitted");
    }
    let allowed = request.method() == Method::CONNECT
        && request.uri().authority().is_some_and(|authority| {
            authority.port_u16() == Some(target.authority_port)
                && (authority.host() == target.hostname
                    || (!target.loopback_alias
                        && authority.host().parse::<IpAddr>().ok() == Some(target.address)))
        });
    if !allowed {
        eprintln!("CONNECT fixture denied {}", request.uri());
        respond.send_response(
            Response::builder().status(StatusCode::FORBIDDEN).body(())?,
            true,
        )?;
        return Ok(());
    }
    let authority = request
        .uri()
        .authority()
        .ok_or_else(|| io::Error::other("missing origin authority"))?;
    let dial = async {
        if target.loopback_alias {
            return TcpStream::connect(SocketAddr::new(target.address, target.port)).await;
        }
        let resolved = tokio::net::lookup_host((authority.host(), target.port))
            .await?
            .find(|address| address.ip() == target.address)
            .ok_or_else(|| {
                io::Error::other("fixture origin resolved outside its assigned address")
            })?;
        TcpStream::connect(resolved).await
    };
    let socket = tokio::select! {
        biased;
        _ = wait_for_revocation(&mut revocation) => {
            eprintln!("CONNECT fixture denied admission before opening tunnel");
            respond.send_response(Response::builder().status(StatusCode::FORBIDDEN).body(())?, true)?;
            return Ok(());
        }
        result = dial => match result {
            Ok(socket) => socket,
            Err(error) => {
                eprintln!("Unable to reach the fixture origin: {error}");
                respond.send_response(Response::builder().status(StatusCode::BAD_GATEWAY).body(())?, true)?;
                return Ok(());
            }
        }
    };
    eprintln!(
        "CONNECT {} resolved {}",
        authority,
        socket.peer_addr()?.ip()
    );
    let mut response = respond.send_response(Response::new(()), false)?;
    let mut request = request.into_body();
    let (mut upstream_read, mut upstream_write) = socket.into_split();

    let revoked = {
        let send_request = async {
            while let Some(chunk) = request.data().await {
                let chunk = chunk?;
                upstream_write.write_all(&chunk).await?;
                request.flow_control().release_capacity(chunk.len())?;
            }
            upstream_write.shutdown().await?;
            Ok::<_, Error>(())
        };
        let send_response = async {
            let mut buffer = [0; 4096];
            loop {
                let length = upstream_read.read(&mut buffer).await?;
                if length == 0 {
                    response.send_data(Bytes::new(), true)?;
                    return Ok::<_, Error>(());
                }
                send_data(&mut response, &buffer[..length]).await?;
            }
        };

        tokio::pin!(send_request);
        tokio::pin!(send_response);
        tokio::select! {
            biased;
            _ = wait_for_revocation(&mut revocation) => true,
            result = &mut send_request => {
                result?;
                tokio::select! {
                    biased;
                    _ = wait_for_revocation(&mut revocation) => true,
                    result = &mut send_response => { result?; false }
                }
            }
            result = &mut send_response => { result?; false }
        }
    };
    if revoked {
        response.send_reset(h2::Reason::CANCEL);
        eprintln!("CONNECT fixture reset an active stream after revocation");
    }
    Ok(())
}

async fn send_data(response: &mut SendStream<Bytes>, mut bytes: &[u8]) -> Result<(), Error> {
    response.reserve_capacity(bytes.len());
    while !bytes.is_empty() {
        let assigned = response.capacity();
        let capacity = if assigned > 0 {
            assigned
        } else {
            poll_fn(|context| response.poll_capacity(context))
                .await
                .ok_or_else(|| io::Error::other("HTTP/2 stream ended before forwarding"))??
        };
        let length = capacity.min(bytes.len());
        if length > 0 {
            response.send_data(Bytes::copy_from_slice(&bytes[..length]), false)?;
            bytes = &bytes[length..];
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn forwarding_uses_http2_credit_already_assigned_to_the_stream() {
        let (client_io, server_io) = tokio::io::duplex(32 * 1024);
        let server = tokio::spawn(async move {
            let mut connection = server::handshake(server_io).await.unwrap();
            let (_, mut respond) = connection.accept().await.unwrap().unwrap();
            let response = respond.send_response(Response::new(()), false).unwrap();
            let send = tokio::spawn(async move {
                let mut response = response;
                response.reserve_capacity(512);
                let assigned = poll_fn(|cx| response.poll_capacity(cx))
                    .await
                    .unwrap()
                    .unwrap();
                assert!(assigned > 0);
                send_data(&mut response, b"origin body").await.unwrap();
                response.send_data(Bytes::new(), true).unwrap();
            });
            tokio::select! {
                _ = connection.accept() => {}
                _ = send => {
                    // Poll the connection to flush the queued response frames and observe client closure.
                    let _ = connection.accept().await;
                }
            }
        });
        let (mut sender, connection) = h2::client::handshake(client_io).await.unwrap();
        let client = tokio::spawn(connection);
        let (response, _) = sender
            .send_request(
                Request::builder()
                    .uri("https://fixture.test")
                    .body(())
                    .unwrap(),
                true,
            )
            .unwrap();
        let received = timeout(Duration::from_secs(1), async move {
            let mut body = response.await.unwrap().into_body();
            let mut received = Vec::new();
            while let Some(bytes) = body.data().await {
                received.extend(bytes.unwrap());
            }
            received
        })
        .await
        .unwrap();
        assert_eq!(received, b"origin body");
        client.abort();
        server.abort();
    }
}
