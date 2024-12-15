const express = require('express');
const { exec } = require('child_process');
const app = express();
const port = 8082;  // Changed port to 8082

app.get('/', (req, res) => {
  res.send('Ollama Web UI - Working');
});

// Endpoint to run Ollama commands via docker exec
app.get('/run', (req, res) => {
  // Replace <your-ollama-command> with a specific Ollama command.
  const ollamaCommand = 'docker exec ollama-container ollama <your-ollama-command>';
  
  // Execute the command in the Ollama container
  exec(ollamaCommand, (err, stdout, stderr) => {
    if (err) {
      res.status(500).send(`Error: ${stderr}`);
    } else {
      res.send(`<pre>${stdout}</pre>`);
    }
  });
});

// Start the web server
app.listen(port, () => {
  console.log(`Web UI running at http://localhost:${port}`);
});
