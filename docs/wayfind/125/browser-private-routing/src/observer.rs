//! Raw loopback forwarder for the fixture. It has no TLS key.

use crate::Error;
use std::{io, net::SocketAddr, sync::Arc, time::Duration};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    time::timeout,
};

pub async fn run(listen: SocketAddr, next: SocketAddr, admission: &str) -> Result<(), Error> {
    if !listen.ip().is_loopback() || !next.ip().is_loopback() || admission.is_empty() {
        return Err(
            io::Error::other("observer requires a loopback fixture and a test marker").into(),
        );
    }
    let markers = Arc::new(vec![
        admission.as_bytes().to_vec(),
        b"RUST_PRIVATE_ORIGIN".to_vec(),
    ]);
    let listener = TcpListener::bind(listen).await?;
    println!("{}", listener.local_addr()?.port());
    loop {
        let (incoming, _) = listener.accept().await?;
        let markers = Arc::clone(&markers);
        tokio::spawn(async move {
            if let Err(error) = bridge(incoming, next, markers).await {
                eprintln!("Observer connection failed: {error}");
            }
        });
    }
}

async fn bridge(
    incoming: TcpStream,
    next: SocketAddr,
    markers: Arc<Vec<Vec<u8>>>,
) -> Result<(), Error> {
    let upstream = timeout(Duration::from_secs(4), TcpStream::connect(next)).await??;
    let (client_read, client_write) = incoming.into_split();
    let (server_read, server_write) = upstream.into_split();
    let client = observe(client_read, server_write, &markers);
    let server = observe(server_read, client_write, &markers);
    let (client_facts, server_facts) = timeout(Duration::from_secs(20), async {
        tokio::join!(client, server)
    })
    .await?;
    let ((sent, uplink_match), (received, downlink_match)) = (client_facts?, server_facts?);
    eprintln!(
        "observer sent={sent} received={received} fixture_marker={}",
        uplink_match || downlink_match
    );
    Ok(())
}

async fn observe(
    mut reader: impl AsyncRead + Unpin,
    mut writer: impl AsyncWrite + Unpin,
    markers: &[Vec<u8>],
) -> Result<(usize, bool), Error> {
    let mut buffer = [0; 4096];
    let retained = markers.iter().map(Vec::len).max().unwrap_or(1) - 1;
    let mut previous = Vec::with_capacity(retained + buffer.len());
    let mut matched = false;
    let mut total = 0;
    loop {
        let length = reader.read(&mut buffer).await?;
        if length == 0 {
            break;
        }
        previous.extend_from_slice(&buffer[..length]);
        matched = matched
            || markers
                .iter()
                .any(|marker| previous.windows(marker.len()).any(|part| part == marker));
        if previous.len() > retained {
            previous.drain(..previous.len() - retained);
        }
        writer.write_all(&buffer[..length]).await?;
        total += length;
    }
    writer.shutdown().await?;
    Ok((total, matched))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn detects_a_marker_split_between_reads_without_changing_bytes() {
        let marker = b"known-fixture-marker".to_vec();
        let mut expected = vec![b'x'; 4094];
        expected.extend_from_slice(&marker);
        let (mut source, input) = tokio::io::duplex(8192);
        let (output, mut receiver) = tokio::io::duplex(8192);
        source.write_all(&expected).await.unwrap();
        source.shutdown().await.unwrap();
        let facts = observe(input, output, &[marker]).await.unwrap();
        let mut actual = Vec::new();
        receiver.read_to_end(&mut actual).await.unwrap();
        assert_eq!(actual, expected);
        assert_eq!(facts, (expected.len(), true));
    }
}
