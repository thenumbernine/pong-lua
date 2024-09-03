#!/usr/bin/env luajit
--[[
TODO gui for local and remote games ...

we want to allow 1-4 players, any of which can be AI or remote connections
remote connections may or may not be players
--]]

local gl = require 'gl'
local ffi = require 'ffi'
local sdl = require 'sdl'
local math = require 'ext.math'
local class = require 'ext.class'
local table = require 'ext.table'
local vec2 = require 'vec.vec2'
local matrix_ffi = require 'matrix.ffi'
local netFieldNumber = require 'netrefl.netfield'.netFieldNumber
local netFieldVec2 = require 'netrefl.netfield_vec'.netFieldVec2
local createNetFieldList = require 'netrefl.netfield_list'.createNetFieldList
local NetCom = require 'netrefl.netcom'
local Server = require 'netrefl.server'
local Audio = require 'audio.audio'
local AudioBuffer = require 'audio.buffer'
local AudioSource = require 'audio.source'

local worldSize = 100	-- biggest size of the game

local Renderer = class()
Renderer.requireClasses = {}

function Renderer:init()
	gl.glPixelStorei(gl.GL_UNPACK_ALIGNMENT, 1)
end

function Renderer:onResize(wx,wy)
	if wx > wy then
		local rx = wx / wy
		self:ortho(-worldSize * (rx - 1) / 2, worldSize * (((rx - 1) / 2) + 1), worldSize, 0, -1, 1)
	else
		local ry = wy / wx
		self:ortho(0, worldSize, worldSize * (((ry - 1) / 2) + 1), -worldSize * (ry - 1) / 2, -1, 1)
	end
end

do
	local GLES2Renderer = class(Renderer)
	Renderer.requireClasses.OpenGLES2 = GLES2Renderer

	local GLProgram
	local GLTex2D
	local shader
	local rmat, smat, rsmat, tmat, mvmat, projmat, mvprojmat
	local color = ffi.new('float[4]')
	local sceneObj
	function GLES2Renderer:init()
		GLES2Renderer.super.init(self)
		GLProgram = require 'gl.program'
		GLTex2D = require 'gl.tex2d'
		shader = GLProgram{
			version = 'latest',
			precision = 'best',
			vertexCode=[[
in vec2 vertex;
out vec2 tc;
uniform mat4 mat;
void main() {
	tc = vertex.xy + vec2(.5, .5);
	gl_Position = mat * vec4(vertex, 0., 1.);
}
]],
			fragmentCode=[[
in vec2 tc;
out vec4 fragColor;
uniform vec4 color;
uniform sampler2D tex;
void main() {
	fragColor = color * texture(tex, tc);
}
]],
			uniforms = {
				tex = 0,
			},
		}:useNone()

		local GLMatrix4x4 = function()
			return matrix_ffi({4,4}, 'float'):zeros()
		end
		rmat = GLMatrix4x4()
		smat = GLMatrix4x4()
		rsmat = GLMatrix4x4()
		tmat = GLMatrix4x4()
		mvmat = GLMatrix4x4()
		projmat = GLMatrix4x4()
		mvprojmat = GLMatrix4x4()

		sceneObj = require 'gl.sceneobject'{
			program = shader,
			vertexes = {
				data = {
					 -.5, -.5,
					  .5, -.5,
					 -.5,  .5,
					  .5,  .5,
				},
				dim = 2,
				count = 4,
			},
			geometry = {
				mode = gl.GL_TRIANGLE_STRIP,
				offset = 0,
				count = 4,
			},
		}
	end

	function GLES2Renderer:createTex2D(filename)
		return GLTex2D{
			filename=filename,
			minFilter=gl.GL_LINEAR,
			magFilter=gl.GL_LINEAR,
		}:unbind()
	end

	function GLES2Renderer:ortho(a,b,c,d,e,f)
		projmat:setOrtho(a,b,c,d,e,f)
	end

	function GLES2Renderer:preRender() end

	function GLES2Renderer:drawBlock(x,y,w,h,th,r,g,b)
		rmat:setRotate(th,0,0,1)
		smat:setScale(w,h,1)
		rsmat:mul4x4(rmat,smat)
		tmat:setTranslate(x,y,0)
		mvmat:mul4x4(tmat,rsmat)
		mvprojmat:mul4x4(projmat, mvmat)
		color[0] = r
		color[1] = g
		color[2] = b
		color[3] = 1

		sceneObj.uniforms.color = color
		sceneObj.uniforms.mat = mvprojmat.ptr
		sceneObj:draw()
	end
end

local testingRemote = false
local useSound = true
local useMouse	-- nil means moving mouse can set it to true ... but touching keyboard sets it to false (can't use mouse after that)
local useTextures = true
local useJoystick = false


local audio
local audioSources
local playBuffer
local playerHitSounds = table()
local blockHitSound
local getItemSound
if useSound then
	audio = Audio()

	playerHitSounds = {AudioBuffer('player1.wav'), AudioBuffer('player2.wav')}
	blockHitSound = AudioBuffer('block.wav')
	getItemSound = AudioBuffer('item.wav')

	-- TODO query from hardware how many simultanoues sources can be played?
	audioSources = table()
	for i=1,8 do
		audioSources:insert(AudioSource())
	end
	audioSources.current = 1

	playBuffer = function(buffer)
		audioSources[audioSources.current]:setBuffer(buffer):play()
		audioSources.current = (audioSources.current % #audioSources) + 1
	end
else
	playBuffer = function() end
end

local time = 0
local lastTime = 0


local Player = class()
Player.score = 0
Player.size = 10
Player.sizeMin = 1
Player.sizeMax = 20
Player.y = 50
Player.vy = 0
Player.speedMin = 1
Player.speedMax = 10
Player.speed = 5
Player.speedScalar = 10
Player.__netfields = {
	y = netFieldNumber,
	score = netFieldNumber,
	index = netFieldNumber,		-- for determining what player hit sound to use
}
Player.xForIndex = {5, worldSize - 5}
Player.nForIndex = {1, -1}	-- x normal for the player
function Player:init(index)
	self.index = index
	self.normal = vec2()
	if index then	-- clientside doesn't know indexes, and doesn't use normals.  if it did you could always sync them
		self.normal[1] = self.nForIndex[index]
	end
end
function Player:move(dy)
	self.vy = self.vy + dy
end
local netFieldPlayer = class(NetFieldObject)
netFieldPlayer.__netallocator = Player


local Ball = class()
Ball.speedMin = 1
Ball.speedMax = 20
Ball.speedScalar = 5
function Ball:init()
	self.pos = vec2()
	self.vel = vec2()
end
function Ball:reset()
	self.pos:set(50,75)
	self.vel:set(-5,5)
end
Ball.__netfields = {
	pos = netFieldVec2,
}
local netFieldBall = class(NetFieldObject)
netFieldBall.__netallocator = Ball


local Block = class()
Block.__netfields = {
	pos = netFieldVec2,
}
function Block:init(args)
	self.pos = args.pos
end
local netFieldBlock = class(NetFieldObject)
netFieldBlock.__netallocator = Block


local Item = class()
Item.speed = 50
Item.__netfields = {
	pos = netFieldVec2,
	type = netFieldNumber,
}
do
	local function changePaddleSize(amount)
		return function(player, game)
			player.size = math.clamp(player.sizeMin, player.size + amount, player.sizeMax)
		end
	end
	local function changePaddleSpeed(amount)
		return function(player, game)
			player.speed = math.clamp(player.speedMin, player.speed + amount, player.speedMax)
		end
	end
	local function changeBallSpeed(amount)
		return function(player, game)
			local ball = game.ball
			local speed = ball.vel[1]
			local absSpeed = math.abs(speed)
			local dir = speed / absSpeed
			absSpeed = math.clamp(ball.speedMin, absSpeed + amount, ball.speedMax)
			game.ball.vel[1] = absSpeed * dir
		end
	end
	Item.types = {
		{
			desc = 'Shrink Paddle',
			color = {1,0,0},
			exec = changePaddleSize(-1),
		},
		{
			desc = 'Grow Paddle',
			color = {0,1,0},
			exec = changePaddleSize(1),
		},
		{
			desc = 'Speed Ball',
			color = {1,1,0},
			exec = changeBallSpeed(1),
		},
		{
			desc = 'Slow Ball',
			color = {1,0,1},
			exec = changeBallSpeed(-1),
		},
		{
			desc = 'Speed Paddle',
			color = {0,1,1},
			exec = changePaddleSpeed(1),
		},
		{
			desc = 'Slow Paddle',
			color = {0,0,1},
			exec = changePaddleSpeed(-1),
		},
	}
end
function Item:init(itemType)
	self.pos = vec2()
	self.vel = vec2()
	self.type = itemType
end
function Item:touch(player, game)	-- TODO subclass
	local itemType = assert(self.types[self.type])
	print('player '..player.index..' got '..itemType.desc)
	itemType.exec(player, game)
end
local netFieldItem = class(NetFieldObject)
netFieldItem.__netallocator = Item


local Game = class()
Game.__netfields = {
	playerA = netFieldPlayer,
	playerB = netFieldPlayer,
	ball = netFieldBall,
	blocks = createNetFieldList(netFieldBlock),
	items = createNetFieldList(netFieldItem),
}
Game.blockGridSize = 25
Game.spawnBlockDuration = 1
function Game:init()
	self.ball = Ball()
	self.playerA = Player(1)
	self.playerB = Player(2)
	self:reset()
end
function Game:reset()
	self.startTime = time + 3
	self.ball:reset()
	self.blocks = table()
	self.items = table()
	self.blockForPos = {}
	self.nextBlockTime = time + self.spawnBlockDuration
end
function Game:update(dt)

	local players = {self.playerA, self.playerB}

	for _,player in ipairs(players) do
		player.y = player.y + player.vy * (player.speedScalar * player.speed * dt)
		player.vy = 0
		if player.y < 0 then player.y = 0 end
		if player.y > worldSize then player.y = worldSize end
	end

	if time < self.startTime then return end

	if time > self.nextBlockTime then
		self.nextBlockTime = time + self.spawnBlockDuration
		local newBlockPos = vec2(math.random(1,self.blockGridSize), math.random(1,self.blockGridSize))
		local blockCol = self.blockForPos[newBlockPos[1]]
		if not blockCol then
			blockCol = {}
			self.blockForPos[newBlockPos[1]] = blockCol
		end
		if not blockCol[newBlockPos[2]] then
			local block = Block{pos=newBlockPos}
			blockCol[newBlockPos[2]] = block
			self.blocks:insert(block)
			self.nextBlockTime = time + self.spawnBlockDuration
		end
	end

	local ball = self.ball

	-- cheat AI
	for index,player in ipairs(players) do
		if not player.serverConn then
			if ball.pos[2] < player.y then
				player:move(-1)
			elseif ball.pos[2] > player.y then
				player:move(1)
			end
		end
	end

	-- update items
	for i=#self.items,1,-1 do
		local item = self.items[i]
		local itemNewPos = item.pos + item.vel * dt

		if item.pos[1] < 0 or item.pos[1] > worldSize then
			self.items:remove(i)
		else
			local minx, maxx = math.min(item.pos[1], itemNewPos[1]), math.max(item.pos[1], itemNewPos[1])
			for playerIndex,player in ipairs(players) do
				local playerX = Player.xForIndex[playerIndex]
				if playerX >= minx
				and playerX <= maxx
				and item.pos[2] >= player.y - player.size * .5
				and item.pos[2] <= player.y + player.size * .5
				then
					self.server:netcall{'getItemSound'}
					item:touch(player, self)
					self.items:remove(i)
					break
				end
			end
		end

		-- item may have been removed...
		item.pos = itemNewPos
	end

	-- update ball
	local step = ball.vel * dt * ball.speedScalar
	local newpos = ball.pos + step

	-- hit far wall?
	local reset = false
	if newpos[1] <= 0 then
		self.playerB.score = self.playerB.score + 1
		reset = true
	elseif newpos[1] >= worldSize then
		reset = true
		self.playerA.score = self.playerA.score + 1
	end
	if reset then
		self:reset()
		do return end
	end

	-- bounce off walls
	if newpos[2] < 0 and ball.vel[2] < 0 then
		self.server:netcall{'blockHitSound'}
		ball.vel[2] = -ball.vel[2]
	end
	if newpos[2] > worldSize and ball.vel[2] > 0 then
		self.server:netcall{'blockHitSound'}
		ball.vel[2] = -ball.vel[2]
	end

	-- bounce off blocks
	-- TODO traceline
	do
		local gridPos = vec2(
			newpos[1] / worldSize * self.blockGridSize,
			newpos[2] / worldSize * self.blockGridSize)
		local blockCol = self.blockForPos[math.ceil(gridPos[1])]
		if blockCol then
			local block = blockCol[math.ceil(gridPos[2])]
			if block then
				local delta = (block.pos - vec2(.5,.5)) - gridPos
				local absDelta = vec2(math.abs(delta[1]), math.abs(delta[2]))
				local n = vec2()
				if absDelta[1] > absDelta[2] then	-- left/right
					n[2] = 0
					if delta[1] > 0 then	-- ball left of block
						n[1] = -1
					else	-- ball right of block
						n[1] = 1
					end
				else	-- up/down
					n[1] = 0
					if delta[2] > 0 then	-- ball going down
						n[2] = -1
					else	-- ball going up
						n[2] = 1
					end
				end

				local nDotV = vec2.dot(n, ball.vel)
				if nDotV < 0 then
					-- hit block
					ball.vel = ball.vel - n * 2 * nDotV
					self.server:netcall{'blockHitSound'}

					-- and remove the block
					self.blocks:removeObject(block)
					blockCol[math.ceil(gridPos[2])] = nil

					if ball.lastHitPlayer
					and math.random() < .2
					then
						local item = Item()
						item.type = math.random(#item.types)
						item.pos[1] = newpos[1]
						item.pos[2] = newpos[2]
						item.vel[1] = -ball.lastHitPlayer.normal[1] * item.speed
						self.items:insert(item)
					end
				end
			end
		end
	end

	-- now test if it hits the paddle
	for index,player in ipairs(players) do
		local playerX = Player.xForIndex[index]

		local frac = (playerX - ball.pos[1]) / step[1]
		if frac >= 0 and frac <= 1 then
			-- ballX is playerX at this point
			local ballY = ball.pos[2] + step[2] * frac

			-- cull values outside of line segment
			if newpos[2] >= player.y - player.size * .5
			and newpos[2] <= player.y + player.size * .5
			then
				local nDotV = vec2.dot(player.normal, ball.vel)
				if nDotV < 0 then
					self.server:netcall{'playerHitSound', player.index}

					ball.vel[1] = -ball.vel[1]
					ball.vel[2] = ((ballY - (player.y - player.size * .5)) / player.size * 2 - 1) * 2 * math.abs(ball.vel[1])
					ball.lastHitPlayer = player
				end
			end
		end
	end

	ball.pos = newpos
end


local game = Game()

local netcom = NetCom()

-- add an object to be reflected
-- addObject means syncing goes both ways ... ?
-- which means delays in coherency may incur ... ?
netcom:addObject{
	name='game',
	object=game,
}

netcom:addClientToServerCall{
	name='setPlayer',
	args={
		netFieldNumber,
	},
	preFunc=function(clientConn, playerNo)
		local player = ({game.playerA, game.playerB})[playerNo]
		if player then
			clientConn.player = player
			player.clientConn = clientConn
		else
			error("bad player "..type(playerNo)..': '..tostring(playerNo))
		end
	end,
	func=function(serverConn, playerNo)	--serverConn is the conn associated with whoever is player2
		local player = ({game.playerA, game.playerB})[playerNo]
		if player then
			serverConn.player = player
			player.serverConn = serverConn
		else
			error("bad player no "..tostring(playerNo))
		end
		print('connecting player '..playerNo)
	end,
}
netcom:addServerToClientCall{
	name='playerHitSound',
	args={
		netFieldNumber,
	},
	func=function(clientConn, playerNo)
		playBuffer(playerHitSounds[(playerNo % #playerHitSounds) + 1])
	end,
}
netcom:addServerToClientCall{
	name='getItemSound',
	func=function(clientConn)
		playBuffer(getItemSound)
	end,
}
netcom:addServerToClientCall{
	name='blockHitSound',
	func=function(clientConn)
		playBuffer(blockHitSound)
	end
}

local remoteGame = false
-- for remote games remoteClientConn is defined
-- for local games server is defined
-- for both clientConn is defined
-- for testingRemote all three are defined, and the (local) clientConn and remoteClientConn are different ClientConn's
local clientConn, server, remoteClientConn = netcom:start{
	port = 12345,
	testingRemote = testingRemote,
	onConnect = function(clientConn)
		if clientConn.serverConn or testingRemote then	-- is local
			clientConn:netcall{'setPlayer', 1}
		else
			clientConn:netcall{'setPlayer', 2}
		end
	end,
}

-- for server->client sending
if server then
	game.server = server
end

local playerTex, blockTex, ballTex, itemTex
local x = ffi.new('int[1]')
local y = ffi.new('int[1]')
local numKeys = ffi.new('int[1]')
local joysticks = {}
local sdlInitFlags = sdl.SDL_INIT_VIDEO
if useJoystick then
	sdlInitFlags = bit.bor(sdlInitFlags, sdl.SDL_INIT_JOYSTICK)
end

local rendererClass = Renderer.requireClasses.OpenGLES2

local GLApp = require 'glapp'
local App = GLApp:subclass()

App.sdlInitFlags = sdlInitFlags
App.title = "Super Pong"

local R -- renderer singleton
function App:initGL()
	R = rendererClass(gl)
	gl.glClearColor(0,0,1,1)
	if useTextures then
		playerTex = R:createTex2D('player.png')
		blockTex = R:createTex2D('block.png')
		ballTex = R:createTex2D('ball.png')
	end
	if useJoystick then
		for i=0,sdl.SDL_NumJoysticks()-1 do
			joysticks[i] = sdl.SDL_JoystickOpen(i)
		end
	end
end

function App:exit()
	audio:shutdown()
	App.super.exit(self)
end

function App:update()
	lastTime = time
	time = sdl.SDL_GetTicks() / 1000
	local deltaTime = time - lastTime

	gl.glDisable(gl.GL_DEPTH_TEST)
	gl.glDisable(gl.GL_CULL_FACE)
	gl.glClear(bit.bor(gl.GL_COLOR_BUFFER_BIT, gl.GL_DEPTH_BUFFER_BIT))

	R:preRender()

	-- TODO draw scores ...

	R:drawBlock(worldSize*.5,worldSize*.5,worldSize,worldSize,0,0,0,0)
	if ballTex then ballTex:bind() end
	R:drawBlock(
		game.ball.pos[1],
		game.ball.pos[2],
		2, 2,
		0,
		1,1,1
	)

	if playerTex then playerTex:bind() end
	for playerIndex,player in ipairs{game.playerA, game.playerB} do
		R:drawBlock(
			Player.xForIndex[playerIndex],
			player.y,
			2, player.size,
			0,
			1,1,1
		)
	end

	if itemTex then itemTex:bind() end
	for _,item in ipairs(game.items) do
		local c = Item.types[item.type].color
		R:drawBlock(
			item.pos[1], item.pos[2],
			3,3,
			180*time,
			c[1], c[2], c[3]
		)
	end

	if blockTex then blockTex:bind() end
	for _,block in ipairs(game.blocks) do
		R:drawBlock(
			(block.pos[1] - .5) / game.blockGridSize * worldSize,
			(block.pos[2] - .5) / game.blockGridSize * worldSize,
			worldSize / game.blockGridSize,
			worldSize / game.blockGridSize,
			0,
			1,1,1
		)
	end

	-- get player input

	if clientConn.player then
		if useMouse then
			sdl.SDL_GetMouseState(x,y)
			local wx, wy = self:size()
			local px = x[0] / wx * worldSize
			local py = y[0] / wy * worldSize
			--clientConn.player.y = worldSize * y[0] / wy
			if py < clientConn.player.y then
				clientConn.player:move(-1)
			elseif py > clientConn.player.y then
				clientConn.player:move(1)
			end
		end

		local keys = sdl.SDL_GetKeyboardState(numKeys)
		if keys[sdl.SDL_SCANCODE_UP] ~= 0 then
			clientConn.player:move(-1)
			useMouse = false
		end
		if keys[sdl.SDL_SCANCODE_DOWN] ~= 0 then
			clientConn.player:move(1)
			useMouse = false
		end

		if joysticks[0] then
			local jy = sdl.SDL_JoystickGetAxis(joysticks[0], 1)
			if jy < -10922 then
				clientConn.player:move(-1)
				useMouse = false
			elseif jy > 10922 then
				clientConn.player:move(1)
				useMouse = false
			end
		end
	end

	game:update(deltaTime)
	netcom:update()
end

function App:resize()
	App.super.resize(self)
	R:onResize(self.width, self.height)
end

function App:event(event)
	if event[0].type == sdl.SDL_KEYDOWN then
		if event[0].key.keysym.sym == sdl.SDLK_ESCAPE then
			self:requestExit()
		end
	elseif event[0].type == sdl.SDL_MOUSEMOTION then
		if useMouse ~= false then	-- only set to true if it has not yet been defined (cleared by keys/joystick)
			useMouse = true
		end
	end
end

return App():run()
