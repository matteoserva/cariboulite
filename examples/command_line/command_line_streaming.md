 
~/cariboulite/build $ ./cariboulite_util -c 1 -f 107000000  -g 30 -r 400000 - | buffer -s 500k| socat - TCP:dest_server:9999
