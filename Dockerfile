FROM node:14

# Set working directory
WORKDIR /usr/src/app

# Copy package.json and install dependencies
COPY package*.json ./
RUN npm install

# Copy the rest of the application
COPY . .

# Expose the port the app runs on (changed to 8082)
EXPOSE 8082

# Run the app
CMD ["node", "server.js"]
