wget -qO- https://raw.githubusercontent.com/nvm-sh/nvm/v0.35.3/install.sh | bash
source ~/.bashrc
nvm --version

# install node js
nvm install stable
node -v
npm -v

nvm alias default stable

