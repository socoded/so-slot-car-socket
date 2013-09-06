var io = require('socket.io').listen(12345);
var mgmt = io.of('/management')
var monitor = io.of('/monitor')

var monitors = []
var mgmtSockets = []

registerMonitorAtMgmt = function(monitorSocket, mgmtSocket) {
  mgmtSocket.emit('monitor_connection', monitorSocket.id)
};

monitor.on('connection', function (socket) {
  monitors.push(socket)

  socket.on('disconnect', function() {
    monitors.splice(monitors.indexOf(this), 1)

    for (var i = 0; i < mgmtSockets.length; i++) {
      mgmtSockets[i].emit('monitor_disconnection', this.id)
    }
  })

  socket.emit('monitor_id', socket.id)

  for (var i = 0; i < mgmtSockets.length; i++) {
    registerMonitorAtMgmt(socket, mgmtSockets[i])
  }
});

mgmt.on('connection', function(socket) {
  mgmtSockets.push(socket)

  socket.on('disconnect', function() {
    mgmtSockets.splice(mgmtSockets.indexOf(this), 1)
  })

  socket.on('command', function(data) {
    for (var i = 0; i < monitors.length; i++) {
      var socket = monitors[i]
      socket.emit('command', data)
    }
  })

  for (var i = 0; i < monitors.length; i++) {
    registerMonitorAtMgmt(monitors[i], socket)
  }
})