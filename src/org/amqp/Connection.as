/**
 * ---------------------------------------------------------------------------
 *   Copyright (C) 2008 0x6e6562
 *
 *   Licensed under the Apache License, Version 2.0 (the "License");
 *   you may not use this file except in compliance with the License.
 *   You may obtain a copy of the License at
 *
 *       http://www.apache.org/licenses/LICENSE-2.0
 *
 *   Unless required by applicable law or agreed to in writing, software
 *   distributed under the License is distributed on an "AS IS" BASIS,
 *   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *   See the License for the specific language governing permissions and
 *   limitations under the License.
 * ---------------------------------------------------------------------------
 **/
package org.amqp
{
    import flash.events.Event;
    import flash.events.IOErrorEvent;
    import flash.events.ProgressEvent;
    import flash.utils.ByteArray;

    import org.amqp.error.ConnectionError;
    import org.amqp.impl.ConnectionStateHandler;
    import org.amqp.impl.SessionImpl;
    import org.amqp.io.SocketDelegate;
    import org.amqp.io.TLSDelegate;
    import org.amqp.methods.connection.CloseOk;

    public class Connection
    {
        private static const CLOSED:int = 0;
        private static const CONNECTING:int = 1;
        private static const CONNECTED:int = 2;

        private var currentState:int = CLOSED;
        private var shuttingDown:Boolean = false;
        private var delegate:IODelegate;
        private var session0:Session;
        private var connectionParams:ConnectionParameters;
        public var sessionManager:SessionManager;
        public var frameMax:int = 0;

        private var currentFrame:Frame = new Frame();

        public function Connection(state:ConnectionParameters) {
            connectionParams = state;
            var stateHandler:ConnectionStateHandler = new ConnectionStateHandler(state);

            session0 = new SessionImpl(this, 0, stateHandler);
            stateHandler.registerWithSession(session0);

            sessionManager = new SessionManager(this);

            if (state.useTLS) {
                delegate = new TLSDelegate;
            }
            else {
                delegate = new SocketDelegate();
            }

            delegate.addEventListener(Event.CONNECT, onSocketConnect);
            delegate.addEventListener(Event.CLOSE, onSocketClose);
            delegate.addEventListener(IOErrorEvent.IO_ERROR, onSocketError);
            delegate.addEventListener(ProgressEvent.SOCKET_DATA, onSocketData);
        }

        public function get baseSession():Session {
            return session0;
        }

        public function start():void {
            if (currentState < CONNECTING) {
                currentState = CONNECTING;
                delegate.open(connectionParams);
            }
        }

        public function isConnected():Boolean {
          return delegate.isConnected();
        }

        public function onSocketConnect(event:Event):void {
            currentState = CONNECTED;
            var header:ByteArray = AMQP.generateHeader();
            delegate.writeBytes(header, 0, header.length);
        }

        public function onSocketClose(event:Event):void {
            currentState = CLOSED;
            handleForcedShutdown();
        }

        public function onSocketError(event:IOErrorEvent):void {
            currentState = CLOSED;
            trace(event.text);
            delegate.dispatchEvent(new ConnectionError());
        }

        public function close(reason:Object = null):void {
            if (!shuttingDown) {
                if (delegate.isConnected()) {
                    handleGracefulShutdown();
                }
                else {
                    handleForcedShutdown();
                }
            }
        }

        public function afterGracefulClose(event:Event):void {
            delegate.close();
        }

        /**
         * Socket timeout waiting for a frame. Maybe missed heartbeat.
         **/
        public function handleSocketTimeout():void {
            handleForcedShutdown();
        }

        private function handleForcedShutdown():void {
            if (!shuttingDown) {
                shuttingDown = true;
                trace("Calling handleForcedShutdown from connection");
                sessionManager.forceClose();
                session0.forceClose();
                delegate.close();
                delegate.dispatchEvent(new ConnectionError());
            }
        }

        private function handleGracefulShutdown():void {
            if (!shuttingDown) {
                shuttingDown = true;
                trace("Calling handleGracefulShutdown from connection, so = " + delegate.isConnected());
                sessionManager.closeGracefully();
                session0.closeGracefully();
                delegate.close();
            }
        }

        /**
         * This parses frames from the network and hands them to be processed
         * by a frame handler.
         **/
        public function onSocketData(event:Event):void {
            while (delegate.isConnected() && delegate.bytesAvailable > 0) {
                var frame:Frame = parseFrame(delegate);
                if (frame == null) return;
                if (frame.type == AMQP.FRAME_HEARTBEAT) {
                  // just ignore this for now
                } else if (frame.channel == 0) {
                    session0.handleFrame(frame);
                } else {
                    var session:Session = sessionManager.lookup(frame.channel);
                    session.handleFrame(frame);
                }
            }
            maybeSendHeartbeat();
        }

        private function parseFrame(delegate:IODelegate):Frame {
 	    currentFrame.readFrom(delegate);
            if (currentFrame.complete) {
	        var frame:Frame = currentFrame;
                currentFrame = new Frame();
                return frame;
            }
            return null;
        }

        public function sendFrame(frame:Frame):void {
            if (delegate.isConnected()) {
                frame.writeTo(delegate);
                delegate.flush();
            } else {
                throw new Error("Connection main loop not running");
            }
        }

        public function addSocketEventListener(type:String, listener:Function):void {
            delegate.addEventListener(type, listener);
        }

        public function removeSocketEventListener(type:String, listener:Function):void {
            delegate.removeEventListener(type, listener);
        }

        private function maybeSendHeartbeat():void {}
    }

}
