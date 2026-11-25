// Throwaway engine feasibility probe. No transport or reconnect implementation.
use anyhow::{bail, Context, Result};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{io::{self, Read, Write}, sync::{Arc, Mutex, Condvar}, time::{Instant, Duration}};
use wezterm_term::{Terminal, TerminalConfiguration, TerminalSize, Intensity, Underline};
use wezterm_term::color::ColorAttribute;
use wezterm_term::color::ColorPalette;

#[derive(Debug)]
struct Config;
impl TerminalConfiguration for Config {
    fn color_palette(&self) -> ColorPalette { ColorPalette::default() }
    fn scrollback_size(&self) -> usize { 40 }
    fn enable_kitty_graphics(&self) -> bool { true }
    fn enable_kitty_keyboard(&self) -> bool { true }
}
#[derive(Clone)]
struct Replies(Arc<(Mutex<Vec<u8>>, Condvar)>);
impl Replies {
    fn new() -> Self { Self(Arc::new((Mutex::new(Vec::new()),Condvar::new()))) }
    fn bytes(&self) -> Result<Vec<u8>> {
        Ok(self.0.0.lock().map_err(|_| anyhow::anyhow!("reply lock poisoned"))?.clone())
    }
    fn drain(&self, terminal: &mut Terminal, event: usize) -> Result<()> {
        let marker = format!("MYTERM_PROBE_WRITER_BARRIER_{event:08}");
        let expected = if terminal.bracketed_paste_enabled() {
            format!("\x1b[200~{marker}\x1b[201~").into_bytes()
        } else { marker.as_bytes().to_vec() };
        // The real engine queues writes to another thread. A public paste into
        // this capture-only sink is a FIFO barrier; it is never sent to a PTY.
        terminal.send_paste(&marker).context("enqueue reply-drain barrier")?;
        let (buffer, changed) = &*self.0;
        let mut bytes = buffer.lock().map_err(|_| anyhow::anyhow!("reply lock poisoned"))?;
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            if bytes.ends_with(&expected) {
                let remaining = bytes.len() - expected.len();
                bytes.truncate(remaining);
                return Ok(());
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() { bail!("reply writer did not reach drain barrier"); }
            let (next, _) = changed.wait_timeout(bytes, remaining).map_err(|_| anyhow::anyhow!("reply lock poisoned"))?;
            bytes = next;
        }
    }
}
impl Write for Replies {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.0.0.lock().map_err(|_| io::Error::other("reply lock poisoned"))?.extend_from_slice(bytes);
        self.0.1.notify_all();
        Ok(bytes.len())
    }
    fn flush(&mut self) -> io::Result<()> { Ok(()) }
}
#[derive(Deserialize)]
struct Event { data: Option<Vec<u8>>, resize: Option<Vec<usize>>, checkpoint: Option<bool> }
#[derive(Deserialize)]
struct Trace { name: String, events: Vec<Event> }

fn snapshot(term: &Terminal, replies: &Replies) -> Result<Value> {
    let size = term.get_size();
    let lines = term.screen().lines_in_phys_range(term.screen().phys_range(&(0..size.rows as i64)));
    let mut cells = vec![vec![String::new(); size.cols]; size.rows];
    let mut widths = vec![vec![0; size.cols]; size.rows];
    let mut attributes = vec![vec![String::new(); size.cols]; size.rows];
    let mut styles = vec![vec!["default|default|falsefalsefalsefalse".to_owned(); size.cols]; size.rows];
    let mut image_cells = 0;
    let mut hyperlinks = Vec::new();
    let mut stored_row_widths = Vec::new();
    let mut hidden_cells = Vec::new();
    for (y, line) in lines.iter().enumerate() {
        let mut stored_width = 0;
        for cell in line.visible_cells() {
            let x = cell.cell_index();
            stored_width = stored_width.max(x + cell.width());
            if y >= size.rows { bail!("out-of-bounds candidate row {y}"); }
            // Alternate buffers may retain columns hidden by a narrower viewport.
            if x >= size.cols {
                hidden_cells.push(json!({"x":x,"y":y,"text":cell.str(),"width":cell.width(),
                    "imageCells":cell.attrs().images().map_or(0, |images| images.len()),
                    "hyperlink":cell.attrs().hyperlink().map(|link|format!("{link:?}"))}));
                continue;
            }
            cells[y][x] = if cell.str() == " " { String::new() } else { cell.str().to_owned() };
            widths[y][x] = cell.width();
            attributes[y][x] = format!("{:?}", cell.attrs());
            let a = cell.attrs();
            let style = format!("{}|{}|{}{}{}{}", color(a.foreground()),color(a.background()),a.intensity()==Intensity::Bold,a.italic(),a.underline()!=Underline::None,a.reverse());
            for col in x..(x+cell.width()).min(size.cols) { styles[y][col] = style.clone(); }
            image_cells += cell.attrs().images().map_or(0, |images| images.len());
            if let Some(link) = cell.attrs().hyperlink() { hyperlinks.push(json!({"x":x,"y":y,"link":format!("{link:?}")})); }
        }
        stored_row_widths.push(stored_width);
    }
    let cursor = term.cursor_pos();
    Ok(json!({"cells":cells,"widths":widths,"attributes":attributes,"styles":styles,"cursor":[cursor.x,cursor.y],
        "alt":term.is_alt_screen_active(), "title":term.get_title(),
        "history":term.screen().phys_row(0), "imageCells":image_cells,"hyperlinks":hyperlinks,
        "storedRowWidths":stored_row_widths,"hiddenCells":hidden_cells,
        "modes":{"applicationCursor":term.application_cursor_keys_enabled(),"bracketedPaste":term.bracketed_paste_enabled(),"mouse":term.mouse_tracking_enabled()},
        "replies":replies.bytes()?}))
}
fn color(c: ColorAttribute) -> String {
    match c {
        ColorAttribute::Default => "default".into(),
        ColorAttribute::PaletteIndex(i) => format!("idx:{i}"),
        ColorAttribute::TrueColorWithPaletteFallback(c,_) | ColorAttribute::TrueColorWithDefaultFallback(c) => {
            let (r,g,b,_) = c.to_srgb_u8(); format!("rgb:{r},{g},{b}")
        }
    }
}
fn run() -> Result<()> {
    let mut bytes = Vec::new(); io::stdin().take(4 * 1024 * 1024 + 1).read_to_end(&mut bytes)?;
    if bytes.len() > 4 * 1024 * 1024 { bail!("trace input exceeds 4 MiB"); }
    let traces: Vec<Trace> = serde_json::from_slice(&bytes).context("decode terminal traces")?;
    let mut output = serde_json::Map::new();
    let cell_width: usize = std::env::var("CELL_WIDTH").context("CELL_WIDTH from measured SwiftTerm baseline")?.parse()?;
    let cell_height: usize = std::env::var("CELL_HEIGHT").context("CELL_HEIGHT from measured SwiftTerm baseline")?.parse()?;
    if !(1..=1024).contains(&cell_width) || !(1..=1024).contains(&cell_height) { bail!("invalid cell geometry"); }
    for trace in traces {
        let replies = Replies::new();
        let start = Instant::now();
        let mut term = Terminal::new(TerminalSize { cols:20, rows:6, pixel_width:20*cell_width, pixel_height:6*cell_height, dpi:96 }, Arc::new(Config), "MyTerm-prototype", "0", Box::new(replies.clone()));
        let startup_us = start.elapsed().as_micros();
        let mut snapshots = Vec::new();
        let mut checkpoint_requests = 0;
        for event in trace.events {
            if let Some(size) = event.resize {
                if size.len()!=2 || size.iter().any(|&n| n==0 || n>1000) { bail!("invalid resize in {}",trace.name); }
                term.resize(TerminalSize { cols:size[0],rows:size[1],pixel_width:size[0]*cell_width,pixel_height:size[1]*cell_height,dpi:96 });
            }
            if let Some(data) = event.data { term.advance_bytes(data); }
            if event.checkpoint == Some(true) { checkpoint_requests += 1; }
            replies.drain(&mut term, snapshots.len())?;
            snapshots.push(snapshot(&term,&replies)?);
        }
        output.insert(trace.name,json!({"snapshots":snapshots,"startupUs":startup_us,"elapsedUs":start.elapsed().as_micros(),"checkpointRequests":checkpoint_requests,
            "checkpoint":"NOT IMPLEMENTED: Rust-to-SwiftTerm transfer remains unproven"}));
    }
    serde_json::to_writer(io::stdout().lock(),&output)?;
    Ok(())
}
fn main() { if let Err(error) = run() { eprintln!("{error:#}"); std::process::exit(1); } }

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;

    #[test]
    fn detached_server_answers_queries_once() -> Result<()> {
        let replies = Replies::new();
        let mut term = Terminal::new(TerminalSize::default(), Arc::new(Config), "probe", "0", Box::new(replies.clone()));
        term.advance_bytes(b"\x1b[3;7H\x1b[6");
        term.advance_bytes(b"n\x1b[5n");
        replies.drain(&mut term, 0)?;
        assert_eq!(replies.bytes()?, b"\x1b[3;7R\x1b[0n");
        Ok(())
    }

    #[test]
    fn dependency_does_not_return_writer_failure() -> Result<()> {
        struct Fails(mpsc::Sender<()>);
        impl Write for Fails {
            fn write(&mut self, _: &[u8]) -> io::Result<usize> {
                self.0.send(()).map_err(|_| io::Error::other("failure observer disconnected"))?;
                Err(io::Error::new(io::ErrorKind::BrokenPipe, "injected query-writer failure"))
            }
            fn flush(&mut self) -> io::Result<()> { Ok(()) }
        }
        let (attempted, observed) = mpsc::channel();
        let mut term = Terminal::new(TerminalSize::default(), Arc::new(Config), "probe", "0", Box::new(Fails(attempted)));
        // advance_bytes returns unit even when its writer fails. An embedding
        // must separately capture writer errors; success cannot mean delivery.
        term.advance_bytes(b"\x1b[6n");
        observed.recv_timeout(Duration::from_secs(2)).context("observe the engine's asynchronous writer failure")?;
        Ok(())
    }
}
