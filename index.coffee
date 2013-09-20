fs = require('fs')
io = require("socket.io").listen(12346)
track = io.of("/track")
master = io.of("/master")

MASTER_PASSWORD = process.env.MASTER_PASSWORD
if !MASTER_PASSWORD? or MASTER_PASSWORD.match(/^\s*$/)
  console.error("No MASTER_PASSWORD set! Run again with MASTER_PASSWORD=yourcrazypassword")
  process.exit(1)

sockets = []
waitingForControll = []
controllers = []

ArrayHelper =
  removeFromLists: (item, lists...) ->
    ArrayHelper.removeFromList(item, list) for list in lists

  removeFromList: (item, list) ->
    index = list.indexOf(item)
    return if index < 0
    list.splice(index, 1)

SerialPort = require("serialport").SerialPort

class Controllers
  constructor: ->
    @controllerCodes = {
      0: 's'
      1: 't'
    }

    @angles = {}
    @angleConfig = {}
    for controller, code of @controllerCodes
      @angles[controller] = 0
      @angleConfig[controller] = {min: 0, max: 10}

    @configFile = __dirname + '/angle_config.json'
    @loadConfig()

  reset: (device) =>
    @serialOptions = {baudrate: 19200, databits: 8, stopbits: 1, parity: 'none'}
    @device = device
    @openSerialPort()

  openSerialPort: =>
    @serialPort.close() if @serialPort?
    @serialPort = new SerialPort @device, @serialOptions
    @resetAngleSettings()

  resetAngleSettings: =>
    @serialPort.write 'r'
    @serialPort.flush()

  override: (controller) =>
    @overrides ||= {}
    @overrides[controller] = true

  release: (controller) =>
    return unless @overrides?
    delete @overrides[controller]

  reconnect: =>
    return unless @isReady()
    @openSerialPort()

  isReady: =>
    @serialPort?

  isOverridden: (controller) =>
    return false unless @overrides?
    @overrides[controller]

  setThrust: (controller, thrust) =>
    controllerCode = @controllerCodes[controller]
    return unless controllerCode?

    thrust = Math.max(0, thrust)
    thrust = Math.min(1, thrust)
    angelConfig = @angleConfig[controller]

    way = 1.0 * angelConfig.max - angelConfig.min

    angle = angelConfig.min + (way * thrust)

    @setAngle(controller, angle)

  setAngle: (controller, angle) =>
    controllerCode = @controllerCodes[controller]
    return unless controllerCode?
    angle = parseInt(angle, 10)
    console.log("SET ANGLE", controller, angle)
    @serialPort.write "#{angle}#{controllerCode}"
    @serialPort.flush()
    @angles[controller] = angle

  setMax: (controller, angle) =>
    @angleConfig[controller].max = angle
    @saveConfig()

  setMin: (controller, angle) =>
    @angleConfig[controller].min = angle
    @saveConfig()

  saveConfig: =>
    fs.writeFile(@configFile, JSON.stringify(@angleConfig))

  loadConfig: =>
    return unless fs.existsSync(@configFile)
    fs.readFile @configFile, (err, data) =>
      return if err?
      @angleConfig = JSON.parse(data)

controllers = new Controllers

class ClientManager
  constructor: (@rawControllers)->
    @clients = []
    @waitingForControll = []
    @controllers = []

  clientConnected: (socket) =>
    client = new Client(@, socket)
    @clients.push client
    socket.on 'controller-proposal', => @receiveControllerProposal(client)
    socket.on 'thrust', ({thrust}) =>
      @rawControllers.setThrust(client.trackNo, thrust) if @isController(client)

    socket.emit('controller-auction') if @controllers.length < 2

  clientDisconnected: (client) =>
    wasController = @isController(client)
    console.log("OLD CONTROLLERS", @controllers.length)

    ArrayHelper.removeFromLists(client, @clients, @waitingForControll, @controllers)

    console.log("NEW CONTROLLERS", @controllers.length)

    if wasController
      client.socket.emit('controller-auction') for client in @clients when !@isController(client)

  receiveControllerProposal: (client) =>
    return if @controllers.length > 1
    newTrackNo = 0
    if @controllers.length > 0
      newTrackNo = if @controllers[0].trackNo is 1 then 0 else 1

    client.trackNo = newTrackNo
    @controllers.push(client)
    console.log("ACCEPTED AS", @controllers.length, client.trackNo, newTrackNo)
    client.socket.emit('accepted-as-controller', track: client.trackNo)

  isController: (client) =>
    @controllers.indexOf(client) >= 0

class Client
  constructor: (@manager, @socket) ->
    @socket.on "disconnect", @disconnected

  disconnected: =>
    @manager.clientDisconnected(@)

class Master
  constructor: (@socket, @controllers) ->
    @socket.on 'authentication-response', @authentication
    @socket.on 'list-devices', @listDevices
    @socket.on 'get-status', @getStatus
    @socket.on 'get-overrides', @getOverrides
    @socket.on 'get-angle-config', @getAngleConfig
    @socket.on 'setup', @setup
    @socket.on 'override', @override
    @socket.on 'release', @release
    @socket.on 'set-angle', @setAngle
    @socket.on 'reconnect', @reconnect
    @socket.on 'set-max', @setMax
    @socket.on 'set-min', @setMin
    @socket.on 'reset-angle-settings', @resetAngleSettings

    @socket.emit('authentication-challenge')

  authentication: ({password}) =>
    if password is MASTER_PASSWORD
      @socket.emit('authentication-success')
    else
      @socket.emit('authentication-failed')
      @socket.disconnect()

  listDevices: =>
    fs.readdir '/dev', (err, files) =>
      return if err?
      realFiles = []
      realFiles.push file for file in files when file.match(/usb/i)
      @socket.emit('devices-list', devices: realFiles)

  getStatus: =>
    @socket.emit('status-update', ready: @controllers.isReady())

  getOverrides: =>
    @socket.emit('overrides-update', overrides: @controllers.overrides || {})

  getAngleConfig: =>
    @socket.emit('angle-config-update', angleConfig: @controllers.angleConfig)

  setup: ({device}) =>
    @controllers.reset("/dev/#{device}")
    @getStatus()

  override: ({controller}) =>
    @controllers.override(controller)
    @getOverrides()

  release: ({controller}) =>
    @controllers.release(controller)
    @getOverrides()

  setAngle: ({controller, angle}) =>
    return unless @controllers.isOverridden(controller)
    @controllers.setAngle(controller, angle)

  reconnect: =>
    @controllers.reconnect()

  setMax: ({controller, angle}) =>
    @controllers.setMax(controller, angle)
    @getAngleConfig()

  setMin: ({controller, angle}) =>
    @controllers.setMin(controller, angle)
    @getAngleConfig()

  resetAngleSettings: =>
    @controllers.resetAngleSettings()

clientManager = new ClientManager(controllers)
track.on "connection", clientManager.clientConnected
master.on "connection", (socket) ->
  new Master(socket, controllers)