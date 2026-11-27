use base64::{engine::general_purpose::STANDARD, Engine};
use myterm_terminal_state::{Geometry, TerminalState};
use serde_json::{from_slice, Value};

const GEOMETRY: Geometry = Geometry {
    columns: 20,
    rows: 6,
    cell_width: 9,
    cell_height: 16,
};

fn first_cell(snapshot: &Value, buffer: &str) -> Result<u8, Box<dyn std::error::Error>> {
    let line = snapshot["state"][buffer]["lines"][0]["cells"]
        .as_str()
        .ok_or("missing encoded cells")?;
    STANDARD
        .decode(line)?
        .get(13)
        .copied()
        .ok_or_else(|| "missing first cell text".into())
}

#[test]
fn checkpoint_preserves_detached_screen_and_unfinished_query(
) -> Result<(), Box<dyn std::error::Error>> {
    let mut terminal = TerminalState::new(GEOMETRY)?;
    terminal.advance(b"detached\x1b[6")?;
    assert!(terminal.take_replies()?.is_empty());

    let snapshot: Value = from_slice(&terminal.checkpoint(42)?)?;
    assert_eq!(snapshot["sequence"], 42);
    assert_eq!(snapshot["pending"], serde_json::json!([27, 91, 54]));
    assert_eq!(first_cell(&snapshot, "normal")?, b'd');

    terminal.advance(b"n")?;
    assert_eq!(terminal.take_replies()?, b"\x1b[1;9R");
    assert!(terminal.take_replies()?.is_empty());
    Ok(())
}

#[test]
fn fresh_client_checkpoint_contains_both_buffers() -> Result<(), Box<dyn std::error::Error>> {
    let mut terminal = TerminalState::new(GEOMETRY)?;
    terminal.advance(b"original\x1b[?1049h\x1b[Halternate\x1b[6")?;
    let snapshot = terminal.checkpoint(42)?;
    let value: Value = from_slice(&snapshot)?;
    assert_eq!(value["state"]["alternateActive"], true);
    assert_eq!(first_cell(&value, "normal")?, b'o');
    assert_eq!(first_cell(&value, "alternate")?, b'a');
    terminal.advance(b"n")?;
    assert_eq!(terminal.take_replies()?, b"\x1b[1;10R");
    Ok(())
}

#[test]
fn unrepresented_palette_rejects_export_without_stopping_terminal(
) -> Result<(), Box<dyn std::error::Error>> {
    let mut terminal = TerminalState::new(GEOMETRY)?;
    terminal.advance(b"\x1b]4;0;rgb:aa/bb/cc\x07")?;
    let failure = terminal
        .checkpoint(50)
        .expect_err("modified palette cannot be imported");
    assert!(failure.to_string().contains("unsupported dynamic palette"));
    terminal.advance(b"\x1b[6n")?;
    assert_eq!(terminal.take_replies()?, b"\x1b[1;1R");
    Ok(())
}

#[test]
fn dense_default_scrollback_fits_the_native_checkpoint_budget(
) -> Result<(), Box<dyn std::error::Error>> {
    let mut terminal = TerminalState::new(Geometry {
        columns: 160,
        rows: 24,
        ..GEOMETRY
    })?;
    let line = (b'A'..=b'Z').cycle().take(160).collect::<Vec<_>>();
    for _ in 0..5_024 {
        terminal.advance(&line)?;
        terminal.advance(b"\r\n")?;
    }
    let checkpoint = terminal.checkpoint(7)?;
    let value: Value = from_slice(&checkpoint)?;
    assert_eq!(value["state"]["scrollback"], 5_000);
    assert_eq!(
        value["state"]["normal"]["lines"].as_array().map(Vec::len),
        Some(5_024)
    );
    assert!(checkpoint.len() <= myterm_terminal_state::MAXIMUM_CHECKPOINT_BYTES);
    if let Some(path) = std::env::var_os("MYTERM_DENSE_CHECKPOINT_FIXTURE") {
        std::fs::write(path, checkpoint)?;
    }
    Ok(())
}

#[test]
fn checkpoint_preserves_unfinished_and_placed_graphics() -> Result<(), Box<dyn std::error::Error>> {
    let mut terminal = TerminalState::new(GEOMETRY)?;
    terminal.advance(b"\x1b_Ga=T,f=32,s=1,v=1,i=7,p=1,c=2,r=1,m=1;/wAA\x1b\\")?;
    let pending = terminal.checkpoint(8)?;
    let snapshot: Value = from_slice(&pending)?;
    assert_eq!(snapshot["state"]["graphics"], serde_json::json!([]));
    assert_eq!(
        snapshot["state"]["kitty"]["pendingCommands"]
            .as_array()
            .map(Vec::len),
        Some(1)
    );
    if let Some(path) = std::env::var_os("MYTERM_PENDING_GRAPHICS_CHECKPOINT_FIXTURE") {
        std::fs::write(path, pending)?;
    }

    terminal.advance(b"\x1b_Gm=0;/w==\x1b\\")?;
    let raster = terminal.checkpoint(9)?;
    let snapshot: Value = from_slice(&raster)?;
    let images = snapshot["state"]["graphics"]
        .as_array()
        .ok_or("missing graphics")?;
    assert_eq!(images.len(), 1);
    assert_eq!(images[0]["displayWidth"], 18);
    assert_eq!(
        snapshot["state"]["kitty"]["pendingCommands"],
        serde_json::json!([])
    );
    if let Some(path) = std::env::var_os("MYTERM_RASTER_CHECKPOINT_FIXTURE") {
        std::fs::write(path, raster)?;
    }
    Ok(())
}

#[test]
fn configured_history_trims_only_the_snapshot() -> Result<(), Box<dyn std::error::Error>> {
    let mut terminal = TerminalState::with_scrollback(
        Geometry {
            columns: 160,
            rows: 24,
            ..GEOMETRY
        },
        100_000,
    )?;
    let suffix = (b'A'..=b'Z').cycle().take(154).collect::<Vec<_>>();
    for line in 0..13_000 {
        terminal.advance(format!("{line:05} ").as_bytes())?;
        terminal.advance(&suffix)?;
        terminal.advance(b"\r\n")?;
    }
    let checkpoint = terminal.checkpoint(10)?;
    let value: Value = from_slice(&checkpoint)?;
    let omitted = value["state"]["omittedScrollbackLines"]
        .as_u64()
        .ok_or("missing omission count")? as usize;
    let lines = value["state"]["normal"]["lines"]
        .as_array()
        .ok_or("missing normal lines")?;
    assert_eq!(value["state"]["scrollback"], 100_000);
    assert!(omitted > 0);
    assert_eq!(omitted + lines.len(), 13_001);
    assert_eq!(terminal.checkpoint(10)?, checkpoint);
    if let Some(path) = std::env::var_os("MYTERM_BOUNDED_CHECKPOINT_FIXTURE") {
        std::fs::write(path, checkpoint)?;
    }
    Ok(())
}

#[test]
fn checkpoint_restores_an_ordinary_kitty_image_above_256_kib(
) -> Result<(), Box<dyn std::error::Error>> {
    let mut terminal = TerminalState::new(Geometry {
        columns: 80,
        rows: 24,
        ..GEOMETRY
    })?;
    let mut pixels = vec![0; 320 * 240 * 4];
    for pixel in pixels.chunks_exact_mut(4) {
        pixel.copy_from_slice(&[212, 36, 129, 255]);
    }
    let payload = STANDARD.encode(&pixels);
    for (index, chunk) in payload.as_bytes().chunks(4096).enumerate() {
        let more = usize::from((index + 1) * 4096 < payload.len());
        let header = if index == 0 {
            format!("\x1b_Ga=T,f=32,s=320,v=240,i=7,p=1,c=36,r=15,m={more};")
        } else {
            format!("\x1b_Gm={more};")
        };
        terminal.advance(header.as_bytes())?;
        terminal.advance(chunk)?;
        terminal.advance(b"\x1b\\")?;
    }
    let checkpoint = terminal.checkpoint(11)?;
    let state: Value = from_slice(&checkpoint)?;
    let resource = &state["state"]["graphics"][0];
    assert_eq!(resource["width"], 320);
    let raw = STANDARD.decode(
        resource["rgba"]
            .as_str()
            .ok_or("missing encoded resource")?,
    )?;
    assert_eq!(raw, pixels);
    if let Some(path) = std::env::var_os("MYTERM_LARGE_GRAPHICS_CHECKPOINT_FIXTURE") {
        std::fs::write(path, checkpoint)?;
    }
    Ok(())
}
