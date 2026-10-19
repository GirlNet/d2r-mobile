vp9-colours.ivf is an authored synthetic fixture, not game content.
34x26, 30 fps, three I420 constant-colour frames: YUV=(64,90,200), (180,150,40), (100,200,100).
Encoded with FFmpeg 7.1/libvpx-vp9, -lossless 1 -g 30 -lag-in-frames 0.
The later packets exercise interframe reference handling.
