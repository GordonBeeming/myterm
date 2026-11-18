"""The historical Kitty trace plus a resize, and native stripe inspection."""
import base64
import plistlib

TRACE = {'name': 'kitty-retained-image', 'events': [
    {'data': list(b'\x1b_Ga=t,f=32,s=1,v=1,i=1;/wAA/w==\x1b\\'
                  b'\x1b_Ga=p,i=1,p=1,c=2,r=1;\x1b\\'), 'checkpoint': True},
    {'data': list(b'\r\n\x1b_Ga=p,i=1,p=2,c=1,r=1;\x1b\\'), 'checkpoint': True},
    {'resize': [24, 8], 'checkpoint': True},
]}
EVENTS = [{'sequence': i, 'event': event} for i, event in enumerate(TRACE['events'])]


def widths(snapshot):
    state = plistlib.loads(base64.b64decode(snapshot['nativeCheckpoint']))['state']
    return [image['pixelWidth'] for line in state['normalBuffer']['lines']
            for image in line.get('images', [])]
