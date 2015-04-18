FROM node:0.12.1

WORKDIR /srv/www/

RUN apt-get update && apt-get dist-upgrade -y && npm install -g coffee-script forever
ADD package.json /srv/www/
RUN npm install

ADD . /srv/www/

WORKDIR /srv/www/
ENV NODE_ENV="production"
CMD npm run startForever
