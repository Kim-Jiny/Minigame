const { io } = require('socket.io-client');
const socket = io('http://localhost:3000', {
  transports: ['polling', 'websocket']
});

socket.on('connect', () => {
  console.log('Socket connected');
  socket.emit('authenticate', { userId: 1, nickname: 'TestUser' });
});

socket.on('authenticated', () => {
  console.log('Authenticated');
  socket.emit('get_friends', {});
});

socket.on('friend_list', (data) => {
  console.log('friend_list received:', data.friends ? data.friends.length : 0, 'friends');
  if (data.friends && data.friends.length > 0) {
    const friend = data.friends[0];
    console.log('First friend:', friend.nickname);
    console.log('Has profileSettings:', friend.profileSettings ? 'yes' : 'no');
    if (friend.profileSettings) {
      console.log('Frame:', friend.profileSettings.activeFrameKey || 'none');
      console.log('Title:', friend.profileSettings.activeTitleKey || 'none');
    }
  }
  socket.disconnect();
  process.exit(0);
});

socket.on('connect_error', (err) => {
  console.log('Connection error:', err.message);
  process.exit(1);
});

setTimeout(() => {
  console.log('Timeout');
  process.exit(1);
}, 5000);
