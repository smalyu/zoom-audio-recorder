"""Set the disk image's Finder layout. Build-only dependencies: ds_store, mac_alias."""
from pathlib import Path
import sys
from ds_store import DSStore
from mac_alias import Alias

mount = Path(sys.argv[1])
background = Alias.for_file(str(mount / '.background' / 'installer.png')).to_bytes()
with DSStore.open(str(mount / '.DS_Store'), 'w+') as store:
    store['.']['bwsp'] = {
        'ShowStatusBar': False, 'ShowTabView': False, 'ShowToolbar': False,
        'ShowPathbar': False, 'ShowSidebar': False, 'ContainerShowSidebar': False,
        'WindowBounds': '{{220, 180}, {640, 460}}',
    }
    store['.']['icvp'] = {
        'viewOptionsVersion': 1, 'backgroundType': 2, 'backgroundImageAlias': background,
        'iconSize': 96.0, 'gridSpacing': 100.0, 'gridOffsetX': 0.0, 'gridOffsetY': 0.0,
        'textSize': 13.0, 'labelOnBottom': True, 'showItemInfo': False,
        'showIconPreview': True, 'arrangeBy': 'none',
    }
    store['.']['vstl'] = ('type', b'icnv')
    store['Zoom Audio Recorder.app']['Iloc'] = (165, 250)
    store['Applications']['Iloc'] = (475, 250)
