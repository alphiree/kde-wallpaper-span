# KDE Wallpaper Slicer

A simple script to span your wallpaper accross multiple displays for KDE Desktop Environments (Wayland or X11).

## Usage

- To run the script:

```sh
# note: ensure you have these packages installed: jq, qt5-tools.
sudo pacman -Sy jq qt5-tools 
```

```sh
chmod +x ./kde-wallpaper-span.sh
./kde-wallpaper-span.sh /path/to/wallpaper.png
```

> NOTE: It applies the wallpaper automatically.

- The script saves one cropped image per active display on the same directory
