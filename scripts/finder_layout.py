"""Set the disk image's Finder layout. Build-only dependencies: ds_store, mac_alias."""
from pathlib import Path
import sys
from ds_store import DSStore
from mac_alias import Alias, ALIAS_EJECTABLE_DISK

mount, volume = Path(sys.argv[1]), sys.argv[2]
# Finder on macOS 26+ resolves the picture only through an alias shaped like its own:
# an ejectable disk mounted under /Volumes, not this build's mount point.
background = Alias.for_file(str(mount / '.background' / 'installer.png'))
background.volume.posix_path = '/Volumes/' + volume
background.volume.disk_type = ALIAS_EJECTABLE_DISK
background.volume.attribute_flags = 0xD02
with DSStore.open(str(mount / '.DS_Store'), 'w+') as store:
    store['.']['vSrn'] = ('long', 1)
    store['.']['bwsp'] = {
        'ShowStatusBar': False, 'ShowTabView': False, 'ShowToolbar': False,
        'ShowPathbar': False, 'ShowSidebar': False, 'ContainerShowSidebar': False,
        # The frame includes the title bar; the picture is 640 × 420.
        'WindowBounds': '{{220, 180}, {640, 432}}',
    }
    store['.']['icvp'] = {
        'viewOptionsVersion': 1, 'backgroundType': 2, 'backgroundImageAlias': background.to_bytes(),
        'backgroundColorRed': 1.0, 'backgroundColorGreen': 1.0, 'backgroundColorBlue': 1.0,
        'iconSize': 96.0, 'gridSpacing': 100.0, 'gridOffsetX': 0.0, 'gridOffsetY': 0.0,
        'textSize': 13.0, 'labelOnBottom': True, 'showItemInfo': False,
        'showIconPreview': True, 'arrangeBy': 'none',
    }
    store['.']['vstl'] = ('type', b'icnv')
    store['Zoom Audio Recorder.app']['Iloc'] = (165, 192)
    store['Applications']['Iloc'] = (475, 192)
    # Out of sight for people who show hidden files in Finder.
    for hidden in ('.background', '.fseventsd', '.VolumeIcon.icns', '.DS_Store', '.Trashes'):
        store[hidden]['Iloc'] = (320, 1000)
