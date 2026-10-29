const express = require('express');
const dotenv = require('dotenv');


// Load environment variables from .env file
dotenv.config();


const app = express();


app.get('/welcome', (req, res) => {
    res.sendFile(__dirname + '/index.html');
});


app.get('/hello', (req, res) => {
    res.send('<p>Hello World!!!</p>');
});


// Get the port from environment variable, fallback to 5000 if not set
const port = process.env.PORT || 5000;


app.listen(port, () => {
    console.log(`Server is running on port ${port}`);
});
