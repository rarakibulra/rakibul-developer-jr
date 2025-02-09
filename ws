#!/bin/bash
if [ $(curl -LI localhost -o /dev/null -w "%{http_code}\n" -s) -eq 000 ];
then
sudo screen -S socks -X kill 
#sudo service openvpn-server@tcp restart
screen -dmS socks python /etc/socks.py 80
fi
