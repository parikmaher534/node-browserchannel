# # Unit tests for BrowserChannel server
#
# This contains all the unit tests to make sure the server works like it should.
#
# This is designed to be run using nodeunit. To run the tests, install nodeunit:
#
#     npm install -g nodeunit
#
# then run the tests with:
#
#     nodeunit tests.coffee
#
# I was thinking of using expresso for this, but I'd be starting up a server for
# every test, and starting the servers in parallel means I might run into the
# default open file limit (256 on macos) with all my tests. Its a shame too, because
# nodeunit annoys me sometimes :)
#
# It might be worth pulling in a higher level HTTP request library from somewhere.
# interacting with HTTP using nodejs's http library is a bit lower level than I'd
# like.
#
# For now I'm not going to add in any SSL testing code. I should probably generate
# a self-signed key pair, start the server using https and make sure that I can
# still use it.

{testCase} = require 'nodeunit'
connect = require 'connect'
browserChannel = require('./lib').server

http = require 'http'
{parse} = require 'url'
assert = require 'assert'
querystring = require 'querystring'

timer = require 'timerstub'

browserChannel._setTimerMethods timer

# Wait for the function to be called a given number of times, then call the callback.
#
# This useful little method has been stolen from ShareJS
expectCalls = (n, callback) ->
	return callback() if n == 0

	remaining = n
	->
		remaining--
		if remaining == 0
			callback()
		else if remaining < 0
			throw new Error "expectCalls called more than #{n} times"

# This returns a function that calls test.done() after it has been called n times. Its
# useful when you want a bunch of mini tests inside one test case.
makePassPart = (test, n) ->
	expectCalls n, -> test.done()


# Most of these tests will make HTTP requests. A lot of the time, we don't care about the
# timing of the response, we just want to know what it was. This method will buffer the
# response data from an http response object and when the whole response has been received,
# send it on.
buffer = (res, callback) ->
	data = []
	res.on 'data', (chunk) ->
		#console.warn chunk.toString()
		data.push chunk.toString 'utf8'
	res.on 'end', -> callback data.join ''

# For some tests we expect certain data, delivered in chunks. Wait until we've
# received at least that much data and strcmp. The response will probably be used more,
# afterwards, so we'll make sure the listener is removed after we're done.
expect = (res, str, callback) ->
	data = ''
	res.on 'end', endlistener = ->
		# This should fail - if the data was as long as str, we would have compared them
		# already. Its important that we get an error message if the http connection ends
		# before the string has been received.
		console.warn 'Connection ended prematurely'
		assert.strictEqual data, str

	res.on 'data', listener = (chunk) ->
		# I'm using string += here because the code is easier that way.
		data += chunk.toString 'utf8'
		#console.warn JSON.stringify data
		#console.warn JSON.stringify str
		if data.length >= str.length
			assert.strictEqual data, str
			res.removeListener 'data', listener
			res.removeListener 'end', endlistener
			callback()

# The backchannel is implemented using a bunch of messages which look like this:
#
# ```
# 36
# [[0,["c","92208FBF76484C10",,8]
# ]
# ]
# ```
#
# They have a length string (in bytes) followed by some JSON data. Google's
# implementation doesn't use strict JSON encoding (like above). They can optionally
# have extra chunks.
#
# This format is used for:
#
# - All XHR backchannel messages
# - The response to the initial connect (XHR or HTTP)
# - The server acknowledgement to forward channel messages
readLengthPrefixedJSON = (res, callback) ->
	data = ''
	length = null
	res.on 'data', listener = (chunk) ->
		data += chunk.toString 'utf8'

		if length == null
			# The number of bytes is written in an int on the first line.
			lines = data.split '\n'
			# If lines length > 1, then we've read the first newline, which was after the length
			# field.
			if lines.length > 1
				length = parseInt lines.shift()

				# Now we'll rewrite the data variable to not include the length.
				data = lines.join '\n'

		if data.length == length
			obj = JSON.parse data
			res.removeListener 'data', listener
			callback obj
		else if data.length > length
			console.warn data
			throw new Error "Read more bytes from stream than expected"

# Copied from google's implementation. The contents of this aren't actually relevant,
# but I think its important that its pseudo-random so if the connection is compressed,
# it still recieves a bunch of bytes after the first message.
ieJunk = "7cca69475363026330a0d99468e88d23ce95e222591126443015f5f462d9a177186c8701fb45a6ffe
e0daf1a178fc0f58cd309308fba7e6f011ac38c9cdd4580760f1d4560a84d5ca0355ecbbed2ab715a3350fe0c47
9050640bd0e77acec90c58c4d3dd0f5cf8d4510e68c8b12e087bd88cad349aafd2ab16b07b0b1b8276091217a44
a9fe92fedacffff48092ee693af\n"

# Most tests will just use the default configuration of browserchannel, but obviously
# some tests will need to customise the options. To customise the options we'll need
# to create a new server object.
#
# So, the code to create servers has been pulled out here for use in tests.
createServer = (opts, method, callback) ->
	# Its possible to use the browserChannel middleware without specifying an options
	# object. This little createServer function will mirror that behaviour.
	if typeof opts == 'function'
		callback = method
		method = opts
		# I want to match up with how its actually going to be used.
		bc = browserChannel method
	else
		bc = browserChannel opts, method
	
	# The server is created using connect middleware. I'll simulate other middleware in
	# the stack by adding a second handler which responds with 200, 'Other middleware' to
	# any request.
	server = connect bc, (req, res, next) ->
		# I might not actually need to specify the headers here... (If you don't, nodejs provides
		# some defaults).
		res.writeHead 200, 'OK', 'Content-Type': 'text/plain'
		res.end 'Other middleware'

	# Calling server.listen() without a port lets the OS pick a port for us. I don't
	# know why more testing frameworks don't do this by default.
	server.listen ->
		# Obviously, we need to know the port to be able to make requests from the server.
		# The callee could check this itself using the server object, but it'll always need
		# to know it, so its easier pulling the port out here.
		port = server.address().port
		callback server, port

module.exports = testCase
	# #### setUp
	#
	# Before each test has run, we'll start a new server. The server will only live
	# for that test and then it'll be torn down again.
	#
	# This makes the tests run more slowly, but not slowly enough that I care.
	setUp: (callback) ->
		# This will make sure there's no pesky setTimeouts from previous tests kicking around.
		# I could instead do a timer.waitAll() in tearDown to let all the timers run & time out
		# the running sessions. It shouldn't be a big deal.
		timer.clearAll()

		# When you instantiate browserchannel, you specify a function which gets called
		# with each client that connects. I'll proxy that function call to a local function
		# which tests can override.
		@onClient = (client) ->
		# The proxy is inline here. Also, I <3 coffeescript's (@server, @port) -> syntax here.
		# That will automatically set this.server and this.port to the callback arguments.
		# 
		# Actually calling the callback starts the test.
		createServer ((client) => @onClient client), (@server, @port) =>

			# I'll add a couple helper methods for tests to easily message the server.
			@get = (path, callback) =>
				http.get {host:'localhost', path, @port}, callback

			@post = (path, data, callback) =>
				req = http.request {method:'POST', host:'localhost', path, @port}, callback
				req.end data

			# One of the most common tasks in tests is to create a new client connection for
			# some reason. @connect is a little helper method for that. It simply sends the
			# http POST to create a new session and calls the callback when the client has been
			# created.
			#
			# It also makes @onClient throw an error - very few tests need multiple clients,
			# so I special case them when they do.
			#
			# Its kind of annoying - for a lot of tests I need to do custom logic in the @post
			# handler *and* custom logic in @onClient. So, callback can be an object specifying
			# callbacks for each if you want that. Its a shame though, it makes this function
			# kinda ugly :/
			@connect = (callback) ->
				# This connect helper method is only useful if you don't care about the initial
				# post response.
				@post '/channel/bind?VER=8&RID=1000&t=1', 'count=0'

				@onClient = (@client) =>
					@onClient = -> throw new Error 'onClient() called - I didn\'t expect another client to be created'
					# Keep this bound. I think there's a fancy way to do this in coffeescript, but
					# I'm not sure what it is.
					callback.call this

			# Finally, start the test.
			callback()

	tearDown: (callback) ->
		# #### tearDown
		#
		# This is called after each tests is done. We'll tear down the server we just created.
		#
		# The next test is run once the callback is called. I could probably chain the next
		# test without waiting for close(), but then its possible that an exception thrown
		# in one test will appear after the next test has started running. Its easier to debug
		# like this.
		@server.on 'close', callback
		@server.close()
	
	# # Testing channel tests
	#
	# The first thing a client does when it connects is issue a GET on /test/?mode=INIT.
	# The server responds with an array of [basePrefix or null,blockedPrefix or null]. Blocked
	# prefix isn't supported by node-browerchannel and by default no basePrefix is set. So with no
	# options specified, this GET should return [null,null].
	'GET /test/?mode=INIT with no baseprefix set returns [null, null]': (test) ->
		@get '/channel/test?VER=8&MODE=init', (response) ->
			test.strictEqual response.statusCode, 200
			buffer response, (data) ->
				test.strictEqual data, '[null,null]'
				test.done()

	# If a basePrefix is set in the options, make sure the server returns it.
	'GET /test/?mode=INIT with a basePrefix set returns [basePrefix, null]': (test) ->
		# You can specify a bunch of host prefixes. If you do, the server will randomly pick between them.
		# I don't know if thats actually useful behaviour, but *shrug*
		# I should probably write a test to make sure all host prefixes will be chosen from time to time.
		createServer hostPrefixes:['chan'], (->), (server, port) ->
			http.get {path:'/channel/test?VER=8&MODE=init', host: 'localhost', port: port}, (response) ->
				test.strictEqual response.statusCode, 200
				buffer response, (data) ->
					test.strictEqual data, '["chan",null]'
					# I'm being slack here - the server might not close immediately. I could make test.done()
					# dependant on it, but I can't be bothered.
					server.close()
					test.done()

	# Setting a custom url endpoint to bind node-browserchannel to should make it respond at that url endpoint
	# only.
	'The test channel responds at a bound custom endpoint': (test) ->
		createServer base:'/foozit', (->), (server, port) ->
			http.get {path:'/foozit/test?VER=8&MODE=init', host: 'localhost', port: port}, (response) ->
				test.strictEqual response.statusCode, 200
				buffer response, (data) ->
					test.strictEqual data, '[null,null]'
					server.close()
					test.done()
	
	# Some people will miss out on the leading slash in the URL when they bind browserchannel to a custom
	# url. That should work too.
	'binding the server to a custom url without a leading slash works': (test) ->
		createServer base:'foozit', (->), (server, port) ->
			http.get {path:'/foozit/test?VER=8&MODE=init', host: 'localhost', port: port}, (response) ->
				test.strictEqual response.statusCode, 200
				buffer response, (data) ->
					test.strictEqual data, '[null,null]'
					server.close()
					test.done()
	
	# Its tempting to think that you need a trailing slash on your URL prefix as well. You don't, but that should
	# work too.
	'binding the server to a custom url with a trailing slash works': (test) ->
		# Some day, the copy+paste police are gonna get me. I don't feel *so* bad doing it for tests though, because
		# it helps readability.
		createServer base:'foozit/', (->), (server, port) ->
			http.get {path:'/foozit/test?VER=8&MODE=init', host: 'localhost', port: port}, (response) ->
				test.strictEqual response.statusCode, 200
				buffer response, (data) ->
					test.strictEqual data, '[null,null]'
					server.close()
					test.done()
	
	# node-browserchannel is only responsible for URLs with the specified (or default) prefix. If a request
	# comes in for a URL outside of that path, it should be passed along to subsequent connect middleware.
	#
	# I've set up the createServer() method above to send 'Other middleware' if browserchannel passes
	# the response on to the next handler.
	'getting a url outside of the bound range gets passed to other middleware': (test) ->
		@get '/otherapp', (response) ->
			test.strictEqual response.statusCode, 200
			buffer response, (data) ->
				test.strictEqual data, 'Other middleware'
				test.done()
	
	# I decided to make URLs inside the bound range return 404s directly. I can't guarantee that no future
	# version of node-browserchannel won't add more URLs in the zone, so its important that users don't decide
	# to start using arbitrary other URLs under channel/.
	#
	# That design decision makes it impossible to add a custom 404 page to /channel/FOO, but I don't think thats a
	# big deal.
	'getting a wacky url inside the bound range returns 404': (test) ->
		@get '/channel/doesnotexist', (response) ->
			test.strictEqual response.statusCode, 404
			test.done()

	# ## Testing phase 2
	#
	# I should really sort the above tests better.
	# 
	# Testing phase 2 the client GETs /channel/test?VER=8&TYPE= [html / xmlhttp] &zx=558cz3evkwuu&t=1 [&DOMAIN=xxxx]
	#
	# The server sends '11111' <2 second break> '2'. If you use html encoding instead, the server sends the client
	# a webpage which calls:
	#
	#     document.domain='mail.google.com';
	#     parent.m('11111');
	#     parent.m('2');
	#     parent.d();
	'Getting test phase 2 returns 11111 then 2': do ->
		makeTest = (type, message1, message2) -> (test) ->
			@get "/channel/test?VER=8&TYPE=#{type}", (response) ->
				test.strictEqual response.statusCode, 200
				expect response, message1, ->
					# Its important to make sure that message 2 isn't sent too soon (<2 seconds).
					# We'll advance the server's clock forward by just under 2 seconds and then wait a little bit
					# for messages from the client. If we get a message during this time, throw an error.
					response.on 'data', f = -> throw new Error 'should not get more data so early'
					timer.wait 1999, ->
						# This is the real `setTimeout` method here. We'll wait 50 milliseconds, which should be way
						# more than enough to get a response from a local server, if its going to give us one.
						setTimeout ->
								response.removeListener 'data', f
								timer.wait 1, ->
									expect response, message2, ->
										response.once 'end', -> test.done()
							, 50

		'xmlhttp': makeTest 'xmlhttp', '11111', '2'

		# I could write this test using JSDom or something like that, and parse out the HTML correctly.
		# ... but it would be way more complicated (and no more correct) than simply comparing the resulting
		# strings.
		'html': makeTest('html',
			# These HTML responses are identical to what I'm getting from google's servers. I think the seemingly
			# random sequence is just so network framing doesn't try and chunk up the first packet sent to the server
			# or something like that.
			"""<html><body><script>try {parent.m("11111")} catch(e) {}</script>\n#{ieJunk}""",
			'''<script>try {parent.m("2")} catch(e) {}</script>
<script>try  {parent.d(); }catch (e){}</script>\n''')

		# If a client is connecting with a host prefix, the server sets the iframe's document.domain to match
		# before sending actual data.
		'html with a host prefix': makeTest('html&DOMAIN=foo.bar.com',
			# I've made a small change from google's implementation here. I'm using double quotes `"` instead of
			# single quotes `'` because its easier to encode. (I can't just wrap the string in quotes because there
			# are potential XSS vulnerabilities if I do that).
			"""<html><body><script>try{document.domain="foo.bar.com";}catch(e){}</script>
<script>try {parent.m("11111")} catch(e) {}</script>\n#{ieJunk}""",
			'''<script>try {parent.m("2")} catch(e) {}</script>
<script>try  {parent.d(); }catch (e){}</script>\n''')
	
	# node-browserchannel is only compatible with browserchannel client v8. I don't know whats changed
	# since old versions (maybe v6 would be easy to support) but I don't care. If the client specifies
	# an old version, we'll die with an error.
	# The alternate phase 2 URL style should have the same behaviour if the version is old or unspecified.
	#
	# Google's browserchannel server still works if you miss out on specifying the version - it defaults
	# to version 1 (which maybe didn't have version numbers in the URLs). I'm kind of impressed that
	# all that code still works.
	'Getting /test/* without VER=8 returns an error': do ->
		# All these tests look 95% the same. Instead of writing the same test all those times, I'll use this
		# little helper method to generate them.
		check400 = (path) -> (test) ->
			@get path, (response) ->
				test.strictEqual response.statusCode, 400
				test.done()

		'phase 1, ver 7': check400 '/channel/test?VER=7&MODE=init'
		'phase 1, no version': check400 '/channel/test?MODE=init'
		'phase 2, ver 7, xmlhttp': check400 '/channel/test?VER=7&TYPE=xmlhttp'
		'phase 2, no version, xmlhttp': check400 '/channel/test?TYPE=xmlhttp'
		# For HTTP connections (IE), the error is sent a different way. Its kinda complicated how the error
		# is sent back, so for now I'm just going to ignore checking it.
		'phase 2, ver 7, http': check400 '/channel/test?VER=7&TYPE=html'
		'phase 2, no version, http': check400 '/channel/test?TYPE=html'
	
	# > At the moment the server expects the client will add a zx=###### query parameter to all requests.
	# The server isn't strict about this, so I'll ignore it in the tests for now.

	# # Server connection tests
	
	# These tests make pretend client connections by crafting raw HTTP queries. I'll make another set of
	# tests later which spam the server with a million fake clients.
	#
	# To start with, simply connect to a server using the BIND API. A client sends a server a few parameters:
	#
	# - **CVER**: Client application version
	# - **RID**: Client-side generated random number, which is the initial sequence number for the
	#   client's requests.
	# - **VER**: Browserchannel protocol version. Must be 8.
	# - **t**: The connection attempt number. This is currently ignored by the BC server. (I'm not sure
	#   what google's implementation does with this).
	'A client connects if it POSTs the right connection stuff': (test) ->
		id = null
		# When a client request comes in, we should get a connected client through the browserchannel
		# server API.
		#
		# We need this client in order to find out the client's ID, which should match up with part of the
		# server's response.
		@onClient = (client) ->
			test.ok client
			test.strictEqual typeof client.id, 'string'
			test.strictEqual client.state, 'init'
			test.strictEqual client.appVersion, '99'
			id = client.id
			client.on 'map', -> throw new Error 'Should not have received data'

		# The client starts a BC connection by POSTing to /bind? with no session ID specified.
		# The client can optionally send data here, but in this case it won't (hence the `count=0`).
		@post '/channel/bind?VER=8&RID=1000&CVER=99&t=1&junk=asdfasdf', 'count=0', (res) =>
			expected = (JSON.stringify [[0, ['c', id, null, 8]]]) + '\n'
			buffer res, (data) ->
				# Even for old IE clients, the server responds in length-prefixed JSON style.
				test.strictEqual data, "#{expected.length}\n#{expected}"
				test.expect 5
				test.done()
	
	# Once a client's session id is sent, the client moves to the `ok` state. This happens after onClient is
	# called (so onClient can send messages to the client immediately).
	#
	# I'm starting to use the @connect method here, which just POSTs locally to create a session, sets @client and
	# calls its callback.
	'A client has state=ok after onClient returns': (test) -> @connect ->
		process.nextTick =>
			test.strictEqual @client.state, 'ok'
			test.done()

	# The CVER= property is optional during client connections. If its left out, client.appVersion is
	# null.
	'A client connects ok even if it doesnt specify an app version': (test) ->
		id = null
		@onClient = (client) ->
			test.strictEqual client.appVersion, null
			id = client.id
			client.on 'map', -> throw new Error 'Should not have received data'

		@post '/channel/bind?VER=8&RID=1000&t=1&junk=asdfasdf', 'count=0', (res) =>
			expected = (JSON.stringify [[0, ['c', id, null, 8]]]) + '\n'
			buffer res, (data) ->
				test.strictEqual data, "#{expected.length}\n#{expected}"
				test.expect 2
				test.done()

	# This time, we'll send a map to the server during the initial handshake. This should be received
	# by the server as normal.
	'The client can post messages to the server during initialization': (test) ->
		@onClient = (client) ->
			client.on 'map', (data) ->
				test.deepEqual data, {k:'v'}
				test.done()

		@post '/channel/bind?VER=8&RID=1000&t=1', 'count=1&ofs=0&req0_k=v', (res) =>
	
	# The data received by the server should be properly URL decoded and whatnot.
	'Messages to the client are properly URL decoded': (test) ->
		@onClient = (client) ->
			client.on 'map', (data) ->
				test.deepEqual data, {"_int_^&^%#net":'hi"there&&\nsam'}
				test.done()

		@post('/channel/bind?VER=8&RID=1000&t=1',
			'count=1&ofs=0&req0__int_%5E%26%5E%25%23net=hi%22there%26%26%0Asam', ->)

	# After a client connects, it can POST data to the server using URL-encoded POST data. This data
	# is sent by POSTing to /bind?SID=....
	#
	# The data looks like this:
	#
	# count=5&ofs=1000&req0_KEY1=VAL1&req0_KEY2=VAL2&req1_KEY3=req1_VAL3&...
	'The client can post messages to the server after initialization': (test) -> @connect ->
		@client.on 'map', (data) ->
			test.deepEqual data, {k:'v'}
			test.done()

		@post "/channel/bind?VER=8&RID=1001&SID=#{@client.id}&AID=0", 'count=1&ofs=0&req0_k=v', (res) =>
	
	# When the server gets a forwardchannel request, it should reply with a little array saying whats
	# going on.
	'The server acknowledges forward channel messages correctly': (test) -> @connect ->
		@post "/channel/bind?VER=8&RID=1001&SID=#{@client.id}&AID=0", 'count=1&ofs=0&req0_k=v', (res) =>
			readLengthPrefixedJSON res, (data) =>
				# The server responds with [backchannelMissing ? 0 : 1, lastSentAID, outstandingBytes]
				test.deepEqual data, [0, 0, 0]
				test.done()

	# If the server has an active backchannel, it responds to forward channel requests notifying the client
	# that the backchannel connection is alive and well.
	'The server tells the client if the backchannel is alive': (test) -> @connect ->
		# This will fire up a backchannel connection to the server.
		req = @get "/channel/bind?VER=8&RID=rpc&SID=#{@client.id}&AID=0&TYPE=xmlhttp", (res) =>
			# The client shouldn't get any data through the backchannel.
			res.on 'data', -> throw new Error 'Should not get data through backchannel'

		# Unfortunately, the GET request is sent *after* the POST, so we have to wrap the
		# post in a timeout to make sure it hits the server after the backchannel connection is
		# established.
		setTimeout =>
				@post "/channel/bind?VER=8&RID=1001&SID=#{@client.id}&AID=0", 'count=1&ofs=0&req0_k=v', (res) =>
					readLengthPrefixedJSON res, (data) =>
						# This time, we get a 1 as the first argument because the backchannel connection is
						# established.
						test.deepEqual data, [1, 0, 0]
						# The backchannel hasn't gotten any data yet. It'll spend 15 seconds or so timing out
						# if we don't abort it manually.
						req.abort()
						test.done()
			, 50
	
	# When the user calls send(), data is queued by the server and sent into the next backchannel connection.
	#
	# The server will use the initial establishing connection if thats available, or it'll send it the next
	# time the client opens a backchannel connection.
	'The server returns data on the initial connection when send is called immediately': (test) ->
		testData = ['hello', 'there', null, 1000, {}, [], [555]]
		@onClient = (@client) =>
			@client.send testData

		@post '/channel/bind?VER=8&RID=1000&t=1', 'count=0', (res) =>
			readLengthPrefixedJSON res, (data) =>
				test.deepEqual data, [[0, ['c', @client.id, null, 8]], [1, testData]]
				test.done()

	'The server buffers data if no backchannel is available': (test) -> @connect ->
		testData = ['hello', 'there', null, 1000, {}, [], [555]]

		# The first response to the server is sent after this method returns, so if we send the data
		# in process.nextTick, it'll get buffered.
		process.nextTick =>
			@client.send testData

			req = @get "/channel/bind?VER=8&RID=rpc&SID=#{@client.id}&AID=0&TYPE=xmlhttp&CI=0", (res) =>
				readLengthPrefixedJSON res, (data) =>
					test.deepEqual data, [[1, testData]]
					req.abort()
					test.done()
	
	# This time, we'll fire up the back channel first (and give it time to get established) _then_
	# send data through the client.
	'The server returns data through the available backchannel when send is called later': (test) -> @connect ->
		testData = ['hello', 'there', null, 1000, {}, [], [555]]

		# Fire off the backchannel request as soon as the client has connected
		req = @get "/channel/bind?VER=8&RID=rpc&SID=#{@client.id}&AID=0&TYPE=xmlhttp&CI=0", (res) ->

			#res.on 'data', (chunk) -> console.warn chunk.toString()
			readLengthPrefixedJSON res, (data) ->
				test.deepEqual data, [[1, testData]]
				req.abort()
				test.done()

		# Send the data outside of the get block to make sure it makes it through.
		setTimeout (=> @client.send testData), 50
	
	# The server should call the send callback once the data has been confirmed by the client.
	#
	# We'll try sending three messages to the client. The first message will be sent during init and the
	# third message will not be acknowledged. Only the first two message callbacks should get called.
	'The server calls send callback once data is acknowledged': (test) -> @connect ->
		lastAck = null

		@client.send [1], ->
			test.strictEqual lastAck, null
			lastAck = 1

		process.nextTick =>
			@client.send [2], ->
				test.strictEqual lastAck, 1
				# I want to give the test time to die
				setTimeout (-> test.done()), 50

			# This callback should actually get called with an error after the client times out.
			@client.send [3], -> throw new Error 'Should not call unacknowledged client callback'

			req = @get "/channel/bind?VER=8&RID=rpc&SID=#{@client.id}&AID=1&TYPE=xmlhttp&CI=0", (res) =>
				readLengthPrefixedJSON res, (data) =>
					test.deepEqual data, [[2, [2]], [3, [3]]]

					# Ok, now we'll only acknowledge the second message by sending dummy client data.
					@post "/channel/bind?VER=8&RID=1001&SID=#{@client.id}&AID=2", 'count=0', (res) =>
						req.abort()

	# If there's a proxy in the way which chunks up responses before sending them on, the client adds a
	# &CI=1 argument on the backchannel. This causes the server to end the HTTP query after each message
	# is sent, so the data is sent to the client.
	'The backchannel is closed after each packet if chunking is turned off': (test) -> @connect ->
		testData = ['hello', 'there', null, 1000, {}, [], [555]]

		process.nextTick =>
			@client.send testData

			# Instead of the usual CI=0 we're passing CI=1 here.
			@get "/channel/bind?VER=8&RID=rpc&SID=#{@client.id}&AID=0&TYPE=xmlhttp&CI=1", (res) =>
				readLengthPrefixedJSON res, (data) =>
					test.deepEqual data, [[1, testData]]

				res.on 'end', -> test.done()

	# Normally, the server doesn't close the connection after each backchannel message.
	'The backchannel is left open if CI=0': (test) -> @connect ->
		testData = ['hello', 'there', null, 1000, {}, [], [555]]

		process.nextTick =>
			@client.send testData

			req = @get "/channel/bind?VER=8&RID=rpc&SID=#{@client.id}&AID=0&TYPE=xmlhttp&CI=0", (res) =>
				readLengthPrefixedJSON res, (data) =>
					test.deepEqual data, [[1, testData]]

				# After receiving the data, the client must not close the connection. (At least, not unless
				# it times out naturally)
				res.on 'end', -> throw new Error 'connection should have stayed open'

				setTimeout ->
						req.abort()
						test.done()
					, 50

	# On IE, the data is all loaded using iframes. The backchannel spits out data using inline scripts
	# in an HTML page.
	#
	# I've written this test separately from the tests above, but it would really make more sense
	# to rerun the same set of tests in both HTML and XHR modes to make sure the behaviour is correct
	# in both instances.
	'The server gives the client correctly formatted backchannel data if TYPE=html': (test) -> @connect ->
		testData = ['hello', 'there', null, 1000, {}, [], [555]]

		process.nextTick =>
			@client.send testData

			# The type is specified as an argument here in the query string. For this test, I'm making
			# CI=1, because the test is easier to write that way.
			#
			# In truth, I don't care about IE support as much as support for modern browsers. This might
			# be a mistake.. I'm not sure. IE9's XHR support should work just fine for browserchannel,
			# though google's BC client doesn't use it.
			@get "/channel/bind?VER=8&RID=rpc&SID=#{@client.id}&AID=0&TYPE=html&CI=1", (res) =>
				expect res,
					# Interestingly, google doesn't double-encode the string like this. Instead of turning
					# quotes `"` into escaped quotes `\"`, it uses unicode encoding to turn them into \42 and
					# stuff like that. I'm not sure why they do this - it produces the same effect in IE8.
					# I should test it in IE6 and see if there's any problems.
					"""<html><body><script>try {parent.m(#{JSON.stringify JSON.stringify([[1, testData]]) + '\n'})} catch(e) {}</script>
#{ieJunk}<script>try  {parent.d(); }catch (e){}</script>\n""", =>
						# Because I'm lazy, I'm going to chain on a test to make sure CI=0 works as well.
						data2 = {other:'data'}
						@client.send data2
						# I'm setting AID=1 here to indicate that the client has seen array 1.
						req = @get "/channel/bind?VER=8&RID=rpc&SID=#{@client.id}&AID=1&TYPE=html&CI=0", (res) =>
							expect res,
								"""<html><body><script>try {parent.m(#{JSON.stringify JSON.stringify([[2, data2]]) + '\n'})} catch(e) {}</script>
#{ieJunk}""", =>
									req.abort()
									test.done()
	
	# If there's a basePrefix set, the returned HTML sets `document.domain = ` before sending messages.
	# I'm super lazy, and just copy+pasting from the test above. There's probably a way to factor these tests
	# nicely, but I'm not in the mood to figure it out at the moment.
	'The server sets the domain if we have a domain set': (test) -> @connect ->
		testData = ['hello', 'there', null, 1000, {}, [], [555]]

		process.nextTick =>
			@client.send testData
			# This time we're setting DOMAIN=X, and the response contains a document.domain= block. Woo.
			@get "/channel/bind?VER=8&RID=rpc&SID=#{@client.id}&AID=0&TYPE=html&CI=1&DOMAIN=foo.com", (res) =>
				expect res,
					"""<html><body><script>try{document.domain=\"foo.com\";}catch(e){}</script>
<script>try {parent.m(#{JSON.stringify JSON.stringify([[1, testData]]) + '\n'})} catch(e) {}</script>
#{ieJunk}<script>try  {parent.d(); }catch (e){}</script>\n""", =>
						data2 = {other:'data'}
						@client.send data2
						req = @get "/channel/bind?VER=8&RID=rpc&SID=#{@client.id}&AID=1&TYPE=html&CI=0&DOMAIN=foo.com", (res) =>
							expect res,
								# Its interesting - in the test channel, the ie junk comes right after the document.domain= line,
								# but in a backchannel like this it comes after. The behaviour here is the same in google's version.
								#
								# I'm not sure if its actually significant though.
								"""<html><body><script>try{document.domain=\"foo.com\";}catch(e){}</script>
<script>try {parent.m(#{JSON.stringify JSON.stringify([[2, data2]]) + '\n'})} catch(e) {}</script>
#{ieJunk}""", =>
									req.abort()
									test.done()

	# If a client thinks their backchannel connection is closed, they might open a second backchannel connection.
	# In this case, the server should close the old one and resume sending stuff using the new connection.
	'The server closes old backchannel connections': (test) -> @connect ->
		testData = ['hello', 'there', null, 1000, {}, [], [555]]

		process.nextTick =>
			@client.send testData

			# As usual, we'll get the sent data through the backchannel connection. The connection is kept open...
			@get "/channel/bind?VER=8&RID=rpc&SID=#{@client.id}&AID=0&TYPE=xmlhttp&CI=0", (res) =>
				readLengthPrefixedJSON res, (data) =>
					# ... and the data has been read. Now we'll open another connection and check that the first connection
					# gets closed.

					req2 = @get "/channel/bind?VER=8&RID=rpc&SID=#{@client.id}&AID=1&TYPE=xmlhttp&CI=0", (res2) =>

					res.on 'end', ->
						req2.abort()
						test.done()

	# The client attaches a sequence number (*RID*) to every message, to make sure they don't end up out-of-order at
	# the server's end.
	#
	# We'll purposefully send some messages out of order and make sure they're held and passed through in order.
	#
	# Gogo gadget reimplementing TCP.
	'The server orders forwardchannel messages correctly using RIDs': (test) -> @connect ->
		# @connect sets RID=1000.

		# We'll send 2 maps, the first one will be {v:1} then {v:0}. They should be swapped around by the server.
		lastVal = 0

		@client.on 'map', (map) ->
			test.strictEqual map.v, "#{lastVal++}", 'messages arent reordered in the server'
			test.done() if map.v == '2'
	
		# First, send `[{v:2}]`
		@post "/channel/bind?VER=8&RID=1002&SID=#{@client.id}&AID=0", 'count=1&ofs=2&req0_v=2', (res) =>
		# ... then `[{v:0}, {v:1}]` a few MS later.
		setTimeout =>
				@post "/channel/bind?VER=8&RID=1001&SID=#{@client.id}&AID=0", 'count=2&ofs=0&req0_v=0&req1_v=1', (res) =>
			, 50
	
	# Again, think of browserchannel as TCP on top of UDP...
	'Repeated forward channel messages are discarded': (test) -> @connect ->
		gotMessage = false
		# The map must only be received once.
		@client.on 'map', (map) ->
			if gotMessage == false
				gotMessage = true
			else
				throw new Error 'got map twice'
	
		# POST the maps twice.
		@post "/channel/bind?VER=8&RID=1001&SID=#{@client.id}&AID=0", 'count=1&ofs=0&req0_v=0', (res) =>
		@post "/channel/bind?VER=8&RID=1001&SID=#{@client.id}&AID=0", 'count=1&ofs=0&req0_v=0', (res) =>

		# Wait 50 milliseconds for the map to (maybe!) be received twice, then pass.
		setTimeout ->
				test.strictEqual gotMessage, true
				test.done()
			, 50

	# With each request to the server, the client tells the server what array it saw last through the AID= parameter.
	#
	# If a client sends a subsequent backchannel request with an old AID= set, that means the client never saw the arrays
	# the server has previously sent. So, the server should resend them.
	'The server resends lost arrays if the client asks for them': (test) -> @connect ->
		process.nextTick =>
			@client.send [1,2,3]
			@client.send [4,5,6]

			@get "/channel/bind?VER=8&RID=rpc&SID=#{@client.id}&AID=0&TYPE=xmlhttp&CI=0", (res) =>
				readLengthPrefixedJSON res, (data) =>
					test.deepEqual data, [[1, [1,2,3]], [2, [4,5,6]]]

					# We'll resend that request, pretending that the client never saw the second array sent (`[4,5,6]`)
					req = @get "/channel/bind?VER=8&RID=rpc&SID=#{@client.id}&AID=1&TYPE=xmlhttp&CI=0", (res) =>
						readLengthPrefixedJSON res, (data) =>
							test.deepEqual data, [[2, [4,5,6]]]
							# We don't need to abort the first connection because the server should close it.
							req.abort()
							test.done()

	# If you sleep your laptop or something, by the time you open it again the server could have timed out your session
	# so your session ID is invalid. This will also happen if the server gets restarted or something like that.
	#
	# The server should respond to any query requesting a nonexistant session ID with 400 and put 'Unknown SID'
	# somewhere in the message. (Actually, the client test is `indexOf('Unknown SID') > 0` so there has to be something
	# before that text in the message or indexOf will return 0.
	#
	# The google servers also set Unknown SID as the http status code, which is kinda neat. I can't check for that.
	'If a client sends an invalid SID in a request, the server responds with 400 Unknown SID': do ->
		testResponse = (test) -> (res) ->
			test.strictEqual res.statusCode, 400
			buffer res, (data) ->
				test.ok data.indexOf('Unknown SID') > 0
				test.done()

		'backChannel': (test) -> @get "/channel/bind?VER=8&RID=rpc&SID=madeup&AID=0&TYPE=xmlhttp&CI=0", testResponse(test)
		'forwardChannel': (test) -> @post "/channel/bind?VER=8&RID=1001&SID=junkyjunk&AID=0", 'count=0', testResponse(test)
		# When type=HTML, google's servers still send the same response back to the client. I'm not sure how it detects
		# the error, but it seems to work. So, I'll copy that behaviour.
		'backChannel with TYPE=html': (test) -> @get "/channel/bind?VER=8&RID=rpc&SID=madeup&AID=0&TYPE=html&CI=0", testResponse(test)
	# When a client connects, it can optionally specify its old session ID and array ID. This solves the old IRC
	# ghosting problem - if the old session hasn't timed out on the server yet, you can temporarily be in a state where
	# multiple connections represent the same user.
	'If a client disconnects then reconnects, specifying OSID= and OAID=, the old session is destroyed': (test) ->
		@post '/channel/bind?VER=8&RID=1000&t=1', 'count=0', (res) =>

		# I want to check the following things:
		#
		# - on 'close' is called on the first client
		# - onClient is called with the second client
		# - on 'close' is called before the second client connects
		#
		# Its kinda gross managing all that state in one function...
		@onClient = (client1) =>
			# As soon as the client has connected, we'll fire off a new connection claiming the previous session is old.
			@post "/channel/bind?VER=8&RID=2000&t=1&OSID=#{client1.id}&OAID=0", 'count=0', (res) =>

			c1Closed = false
			client1.on 'close', ->
				c1Closed = true

			# Once the first client has connected, I'm replacing @onClient so the second client's state can be handled
			# separately.
			@onClient = (client2) ->
				test.ok c1Closed
				test.strictEqual client1.state, 'closed'

				test.done()

	# The server might have already timed out an old connection. In this case, the OSID is ignored.
	'The server ignores OSID and OAID if the named session doesnt exist': (test) ->
		@post "/channel/bind?VER=8&RID=2000&t=1&OSID=doesnotexist&OAID=0", 'count=0', (res) =>

		# So small & pleasant!
		@onClient = (client) =>
			test.ok client
			test.done()

	# OAID is set in the ghosted connection as a final attempt to flush arrays.
	'The server uses OAID to confirm arrays in the old session before closing it': (test) -> @connect ->
		# We'll follow the same pattern as the first callback test waay above. We'll send three messages, one
		# in the first callback and two after. We'll pretend that just the first two messages made it through.
		lastMessage = null

		# We'll create a new client in a moment, so its fine if another client gets made.
		@onClient = ->

		@client.send 1, (error) ->
			test.ifError error
			test.strictEqual lastMessage, null
			lastMessage = 1

		# The final message callback should get called after the close event fires
		@client.on 'close', ->
			test.strictEqual lastMessage, 2

		process.nextTick =>
			@client.send 2, (error) ->
				test.ifError error
				test.strictEqual lastMessage, 1
				lastMessage = 2

			@client.send 3, (error) ->
				test.ok error
				test.strictEqual lastMessage, 2
				lastMessage = 3
				test.strictEqual error.message, 'Reconnected'

				setTimeout (-> req.abort(); test.done()), 50

			# And now we'll nuke the session and confirm the first two arrays. But first, its important
			# the client has a backchannel to send data to (confirming arrays before a backchannel is opened
			# to receive them is undefined and probably does something bad)
			req = @get "/channel/bind?VER=8&RID=rpc&SID=#{@client.id}&AID=1&TYPE=xmlhttp&CI=0", (res) =>

			@post "/channel/bind?VER=8&RID=2000&t=1&OSID=#{@client.id}&OAID=2", 'count=0', (res) =>

	'The client times out after awhile if it doesnt have a backchannel': (test) -> @connect ->
		start = timer.Date.now()
		@client.on 'close', (reason) ->
			test.strictEqual reason, 'Timed out'
			# It should take at least 30 seconds.
			test.ok timer.Date.now() - start >= 30000
			test.done()

		timer.waitAll()

	# There's a slightly different codepath after a backchannel is opened then closed again. I want to make
	# sure it still works in this case.
	# 
	# Its surprising how often this test fails.
	'The client times out if its backchannel is closed': (test) -> @connect ->
		process.nextTick =>
			req = @get "/channel/bind?VER=8&RID=rpc&SID=#{@client.id}&AID=0&TYPE=xmlhttp&CI=0", (res) =>

			# I'll let the backchannel establish itself for a moment, and then nuke it.
			setTimeout =>
					req.abort()
					# It should take about 30 seconds from now to timeout the connection.
					start = timer.Date.now()
					@client.on 'close', (reason) ->
						test.strictEqual reason, 'Timed out'
						test.ok timer.Date.now() - start >= 30000
						test.done()

					# The timer sessionTimeout won't be queued up until after the abort() message makes it
					# to the server. I hate all these delays, but its not easy to write this test without them.
					setTimeout (-> timer.waitAll()), 50
				, 50

	# The server sends a little heartbeat across the backchannel every 20 seconds if there hasn't been
	# any chatter anyway. This keeps the machines en route from evicting the backchannel connection.
	# (noops are ignored by the client.)
	'A heartbeat is sent across the backchannel (by default) every 20 seconds': (test) -> @connect ->
		start = timer.Date.now()

		process.nextTick =>
			req = @get "/channel/bind?VER=8&RID=rpc&SID=#{@client.id}&AID=0&TYPE=xmlhttp&CI=0", (res) =>
				readLengthPrefixedJSON res, (msg) ->
					test.deepEqual msg, [[1, ['noop']]]
					test.ok timer.Date.now() - start >= 20000
					req.abort()
					test.done()

			# Once again, we can't call waitAll() until the request has hit the server.
			setTimeout (-> timer.waitAll()), 50

	# The send callback should be called _no matter what_. That means if a connection times out, it should
	# still be called, but we'll pass an error into the callback.
	'The server calls send callbacks with an error':
		'when the client times out': (test) -> @connect ->
			# It seems like this message shouldn't give an error, but it does because the client never confirms that
			# its received it.
			@client.send 'hello there', (error) ->
				test.ok error
				test.strictEqual error.message, 'Timed out'

			process.nextTick =>
				@client.send 'Another message', (error) ->
					test.ok error
					test.strictEqual error.message, 'Timed out'
					test.expect 4
					test.done()

				timer.waitAll()

		'when the client is ghosted': (test) -> @connect ->
			# As soon as the client has connected, we'll fire off a new connection claiming the previous session is old.
			@post "/channel/bind?VER=8&RID=2000&t=1&OSID=#{@client.id}&OAID=0", 'count=0', (res) =>

			@client.send 'hello there', (error) ->
				test.ok error
				test.strictEqual error.message, 'Reconnected'

			process.nextTick =>
				@client.send 'hi', (error) ->
					test.ok error
					test.strictEqual error.message, 'Reconnected'
					test.expect 4
					test.done()

			# Ignore the subsequent connection attempt
			@onClient = ->

		# The server can also abandon a connection by calling .abort(). Again, this should trigger error callbacks.
		'when the client is aborted by the server': (test) -> @connect ->

			@client.send 'hello there', (error) ->
				test.ok error
				test.strictEqual error.message, 'foo'

			process.nextTick =>
				@client.send 'hi', (error) ->
					test.ok error
					test.strictEqual error.message, 'foo'
					test.expect 4
					test.done()

				@client.abort 'foo'

	# Close() is the API for 'stop trying to connect - something is wrong'. This triggers a STOP error in the
	# client.
	'Calling close() sends the stop command to the client':
		'during init': (test) ->
			@post '/channel/bind?VER=8&RID=1000&t=1', 'count=0', (res) =>
				readLengthPrefixedJSON res, (data) =>
					test.deepEqual data, [[0, ['c', @client.id, null, 8]], [1, ['stop']]]
					test.expect 2
					test.done()

			@onClient = (@client) =>
				@client.close()

				@client.on 'close', (message) ->
					test.strictEqual message, 'Closed'

		'after init': (test) -> @connect ->
			# The stop message will be sent in the back channel. Once the server has sent stop, it should
			# close the backchannel. so we can use buffer to  and trigger on 'close'.
			@get "/channel/bind?VER=8&RID=rpc&SID=#{@client.id}&AID=0&TYPE=xmlhttp&CI=0", (res) =>
				readLengthPrefixedJSON res, (data) ->
					test.deepEqual data, [[1, ['stop']]]

					res.on 'end', ->
						test.done()

			setTimeout (=> @client.close()), 50

			@client.on 'close', (message) ->
				test.strictEqual message, 'Closed'

	'After close() is called, no maps are emitted by the client': (test) -> test.done()

	'Calling close() during the initial connection stops the client immediately': (test) -> test.done()

	'Client.close() makes subsequent client messages return an error': (test) -> test.done()

	'Client.abort() closes the connection': (test) -> test.done()

	'The server sends heartbeat messages on the backchannel, which keeps it open': (test) -> test.done()

	'If a client times out, unacknowledged messages have an error callback called': (test) -> test.done()

	'The server sends accept:JSON header': (test) -> test.done()

	'The server accepts JSON data': (test) -> test.done()
	
	'Connecting with a version thats not 8 breaks': (test) -> test.done()

#server = connect browserChannel (client) ->
#	if client.address != '127.0.0.1' or client.appVersion != '10'
#		client.close()
#
#	client.on 'map', (data) ->
#		console.log data
#	
#	client.send ['hi']
#
#	setInterval (-> client.send ['yo dawg']), 3000
#
#	client.on 'close', ->
		# Clean up
#server.listen(4321)

# # Tests
#
# The browserchannel service exposes 2 API endpoints
#
# ## Test Service
#	
