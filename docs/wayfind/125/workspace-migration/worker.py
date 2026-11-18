"""Disposable process used to observe abrupt exits and restart from real disk state."""
import sys
from pathlib import Path
from migration import migrate

if __name__ == '__main__':
    source, target, decoder, fault, channel = sys.argv[1:]
    migrate(Path(source), Path(target), Path(decoder), fault=fault, channel=channel)
