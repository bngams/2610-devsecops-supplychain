FROM node:latest

# default dir
WORKDIR /app

# get sources
COPY . .

# install/build app
RUN npm install --production

# CONTAIER EXECUTION
CMD ["node", "index.js"]