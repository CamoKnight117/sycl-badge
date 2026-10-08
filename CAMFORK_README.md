# Software You Can Love Badge

This fork is for work on SYCL-Snake, a 2d Snake game built for the badge.
There are currently two working versions, one with a massively larger map and less balanced gameplay (but still fun),
and one that shrank the map and attempted to balance where threat of collision with your own tail was higher, and gameplay
is a bit faster. V2 is the more developed version, with audio and better visuals.

You can build the game along with the other SYCL badge carts by running the command:

zig build

in the root folder (sycl-badge). This will build all of the carts along with their simulator executables.

The files for SYCL-Snake can be found in the following places:

Source code:
\carts\sycl-snake\src\main.zig
\carts\sycl-snake-v2\src\main.zig

After building, you will have two outputted files for each version of SYCL Snake. One will be the simulator executable, 
and the other will be a .uf2 file you can put onto the SYCL badge to run the game from there. Those are found in the following places:

\zig-out\carts              
\zig-out\sim

See the sycl-badge README for additional information. Have fun!





