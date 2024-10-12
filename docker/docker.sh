
#Got permission denied while trying to connect to the Docker daemon 
sudo groupadd docker

sudo gpasswd -a $USER docker

newgrp docker

docker version
