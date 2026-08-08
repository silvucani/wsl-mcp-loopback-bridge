// Runs on WINDOWS (node.exe), started from WSL by bridge.sh.
// Listens on every interface so WSL can reach it, forwards to the Windows loopback
// where the MCP app is bound. Nothing here rewrites HTTP: the bytes pass through
// untouched, which is what keeps the client's Host header intact.

const net = require('net');

const listenPort = Number(process.argv[2]);
const targetPort = Number(process.argv[3]);

if (!listenPort || !targetPort) {
  console.error('usage: node relay.js <listen-port> <target-port>');
  process.exit(2);
}

const server = net.createServer((client) => {
  const upstream = net.connect(targetPort, '127.0.0.1');
  const close = () => {
    client.destroy();
    upstream.destroy();
  };
  client.on('error', close);
  upstream.on('error', close);
  client.on('close', close);
  upstream.on('close', close);
  client.pipe(upstream);
  upstream.pipe(client);
});

server.on('error', (err) => {
  if (err.code === 'EADDRINUSE') {
    console.error(`port ${listenPort} is already in use, assuming a relay is already running`);
    process.exit(0);
  }
  console.error(err.message);
  process.exit(1);
});

server.listen(listenPort, '0.0.0.0', () => {
  console.log(`relay listening on 0.0.0.0:${listenPort} -> 127.0.0.1:${targetPort}`);
});
