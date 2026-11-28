use std::io::{self, Write};
use std::sync::{Arc, Mutex, MutexGuard};
use wezterm_term::color::ColorPalette;
use wezterm_term::{Terminal, TerminalConfiguration, TerminalSize};

pub const MAXIMUM_CHECKPOINT_BYTES: usize = 32 * 1024 * 1024;
const MAXIMUM_REPLIES: usize = 256 * 1024;
pub const DEFAULT_SCROLLBACK: usize = 5_000;
pub const MAXIMUM_SCROLLBACK: usize = 100_000;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Geometry {
    pub columns: u16,
    pub rows: u16,
    pub cell_width: u16,
    pub cell_height: u16,
}

impl Geometry {
    pub fn validate(self) -> io::Result<()> {
        self.terminal_size().map(drop)
    }

    fn terminal_size(self) -> io::Result<TerminalSize> {
        let cols = usize::from(self.columns);
        let rows = usize::from(self.rows);
        let pixel_width = cols * usize::from(self.cell_width);
        let pixel_height = rows * usize::from(self.cell_height);
        if !(2..=1000).contains(&cols)
            || !(1..=1000).contains(&rows)
            || self.cell_width > 1_024
            || self.cell_height > 1_024
            || pixel_width == 0
            || pixel_height == 0
            || pixel_width > usize::from(u16::MAX)
            || pixel_height > usize::from(u16::MAX)
            || cols * rows > 262_144
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Terminal geometry exceeds the checkpoint limits",
            ));
        }
        Ok(TerminalSize {
            rows,
            cols,
            pixel_width,
            pixel_height,
            dpi: 0,
        })
    }
}

#[derive(Debug)]
struct Configuration {
    scrollback: usize,
}

impl TerminalConfiguration for Configuration {
    fn color_palette(&self) -> ColorPalette {
        ColorPalette::default()
    }

    fn scrollback_size(&self) -> usize {
        self.scrollback
    }

    fn enable_kitty_graphics(&self) -> bool {
        true
    }

    fn enable_kitty_keyboard(&self) -> bool {
        true
    }
}

struct ReplyBuffer {
    bytes: Vec<u8>,
    completed: usize,
    limit: usize,
    overflow: bool,
}

impl Default for ReplyBuffer {
    fn default() -> Self {
        Self {
            bytes: Vec::new(),
            completed: 0,
            limit: MAXIMUM_REPLIES,
            overflow: false,
        }
    }
}

pub struct ReplyBatch {
    pub bytes: Vec<u8>,
    pub overflow: bool,
}

#[derive(Clone, Default)]
struct ReplyWriter(Arc<Mutex<ReplyBuffer>>);

impl ReplyWriter {
    fn buffer(&self) -> io::Result<MutexGuard<'_, ReplyBuffer>> {
        self.0
            .lock()
            .map_err(|_| io::Error::other("Terminal reply buffer was poisoned"))
    }

    fn checked_buffer(&self) -> io::Result<MutexGuard<'_, ReplyBuffer>> {
        let buffer = self.buffer()?;
        if buffer.overflow {
            return Err(io::Error::other("Terminal reply queue limit exceeded"));
        }
        Ok(buffer)
    }
}

impl Write for ReplyWriter {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        let mut buffer = self.buffer()?;
        if buffer.overflow || bytes.len() > buffer.limit - buffer.bytes.len() {
            // WezTerm can write parts of the same answer before flushing it.
            // Never deliver the prefix of a response we could not finish.
            let completed = buffer.completed;
            buffer.bytes.truncate(completed);
            buffer.overflow = true;
            // WezTerm wraps this sink in a BufWriter. Returning an I/O error
            // retains bytes there to retry after the overflow flag is reset.
            return Ok(bytes.len());
        }
        buffer.bytes.extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        let mut buffer = self.buffer()?;
        buffer.completed = buffer.bytes.len();
        Ok(())
    }
}

/// Headless state owned by the PTY event loop. Apply output and resizes in delivery order.
/// The owner also drains replies into its ordered PTY input queue.
pub struct TerminalState {
    terminal: Terminal,
    writer: ReplyWriter,
}

impl TerminalState {
    pub fn new(geometry: Geometry) -> io::Result<Self> {
        Self::with_scrollback(geometry, DEFAULT_SCROLLBACK)
    }

    pub fn with_scrollback(geometry: Geometry, scrollback: usize) -> io::Result<Self> {
        if scrollback > MAXIMUM_SCROLLBACK {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Terminal history exceeds 100,000 lines",
            ));
        }
        let writer = ReplyWriter::default();
        let terminal = Terminal::new(
            geometry.terminal_size()?,
            Arc::new(Configuration { scrollback }),
            "MyTerm",
            env!("CARGO_PKG_VERSION"),
            Box::new(writer.clone()),
        );
        Ok(Self { terminal, writer })
    }

    pub fn advance(&mut self, bytes: &[u8]) -> io::Result<()> {
        drop(self.writer.checked_buffer()?);
        self.terminal.advance_bytes(bytes);
        self.writer.checked_buffer().map(drop)
    }

    pub fn advance_with_reply_budget(
        &mut self,
        bytes: &[u8],
        budget: usize,
    ) -> io::Result<ReplyBatch> {
        {
            let mut buffer = self.writer.checked_buffer()?;
            if !buffer.bytes.is_empty() {
                return Err(io::Error::other(
                    "Terminal replies must be drained before starting a delivery batch",
                ));
            }
            buffer.limit = budget.min(MAXIMUM_REPLIES);
        }
        self.terminal.advance_bytes(bytes);
        let mut buffer = self.writer.buffer()?;
        let finished = std::mem::take(&mut *buffer);
        Ok(ReplyBatch {
            bytes: finished.bytes,
            overflow: finished.overflow,
        })
    }

    pub fn resize(&mut self, geometry: Geometry) -> io::Result<()> {
        drop(self.writer.checked_buffer()?);
        self.terminal.resize(geometry.terminal_size()?);
        self.writer.checked_buffer().map(drop)
    }

    pub fn checkpoint(&self, sequence: u64) -> io::Result<Vec<u8>> {
        drop(self.writer.checked_buffer()?);
        self.terminal
            .myterm_checkpoint(sequence)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
    }

    pub fn take_replies(&mut self) -> io::Result<Vec<u8>> {
        let mut buffer = self.writer.checked_buffer()?;
        buffer.completed = 0;
        Ok(std::mem::take(&mut buffer.bytes))
    }
}
