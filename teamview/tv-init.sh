echo start init teamview...

sudo teamviewer daemon stop
sudo mv /opt/teamviewer/config/global.conf /opt/teamviewer/config/global.conf.bak
sudo teamviewer daemon start


echo teamview init complete

echo start init anydesk...
sudo systemctl stop anydesk.service
sudo mv /home/bigbox/.anydesk/system.conf  /home/bigbox/.anydesk/system.conf.bak
sudo mv /home/bigbox/.anydesk/service.conf  /home/bigbox/.anydesk/service.conf.bak

sudo mv /etc/anydesk/system.conf /etc/anydesk/system.conf.bak
sudo mv /etc/anydesk/service.conf /etc/anydesk/service.conf.bak

sudo systemctl start anydesk.service
echo anydesk init complete

rm -rf $0
