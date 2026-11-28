use crate::server::{flush, queue_frame, MAX_FRAME};
use myterm_terminal_state::{Geometry, ReplyBatch, TerminalState};
use std::collections::VecDeque;
use std::io::{self, Write};
use std::panic::{catch_unwind, AssertUnwindSafe};

const CHECKPOINT_BEGIN: u8 = 0x86;
const CHECKPOINT_CHUNK: u8 = 0x87;

pub struct LiveTerminalState {
    terminal: TerminalState,
    sequence: u64,
}

impl LiveTerminalState {
    pub fn new(geometry: Geometry, scrollback: usize) -> io::Result<Self> {
        Ok(Self {
            terminal: TerminalState::with_scrollback(geometry, scrollback)?,
            sequence: 0,
        })
    }

    fn next_sequence(&self) -> io::Result<u64> {
        self.sequence
            .checked_add(1)
            .ok_or_else(|| io::Error::other("Terminal delivery sequence exhausted"))
    }

    pub fn advance(&mut self, bytes: &[u8], reply_budget: usize) -> io::Result<ReplyBatch> {
        let sequence = self.next_sequence()?;
        // The event loop discards this state and stops just this PTY if the
        // parser unwinds. Never resume from a potentially partial mutation.
        let replies = catch_unwind(AssertUnwindSafe(|| {
            self.terminal.advance_with_reply_budget(bytes, reply_budget)
        }))
        .map_err(|_| io::Error::other("Terminal output parser panicked"))??;
        self.sequence = sequence;
        Ok(replies)
    }

    pub fn resize(&mut self, geometry: Geometry) -> io::Result<()> {
        let sequence = self.next_sequence()?;
        self.terminal.resize(geometry)?;
        self.sequence = sequence;
        Ok(())
    }

    pub fn snapshot(&self) -> io::Result<(u64, Vec<u8>)> {
        Ok((self.sequence, self.terminal.checkpoint(self.sequence)?))
    }
}

pub struct SnapshotDelivery {
    bytes: Vec<u8>,
    position: usize,
    frame: VecDeque<u8>,
}

impl SnapshotDelivery {
    pub fn new(sequence: u64, bytes: Vec<u8>, mut leading_frames: VecDeque<u8>) -> Self {
        let mut begin = [0; 12];
        begin[..8].copy_from_slice(&sequence.to_be_bytes());
        begin[8..].copy_from_slice(&(bytes.len() as u32).to_be_bytes());
        queue_frame(&mut leading_frames, CHECKPOINT_BEGIN, &begin);
        Self {
            bytes,
            position: 0,
            frame: leading_frames,
        }
    }

    pub fn retained_bytes(&self) -> usize {
        self.bytes.len()
    }

    pub fn flush(&mut self, stream: &mut impl Write) -> io::Result<bool> {
        for _ in 0..2 {
            flush(&mut self.frame, stream)?;
            if !self.frame.is_empty() {
                return Ok(false);
            }
            if self.position == self.bytes.len() {
                return Ok(true);
            }
            let end = (self.position + MAX_FRAME).min(self.bytes.len());
            queue_frame(
                &mut self.frame,
                CHECKPOINT_CHUNK,
                &self.bytes[self.position..end],
            );
            self.position = end;
        }
        Ok(false)
    }
}
