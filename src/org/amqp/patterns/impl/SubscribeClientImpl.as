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
package org.amqp.patterns.impl
{
	import com.ericfeminella.utils.HashMap;
	
	import de.polygonal.ds.ArrayedQueue;
	
	import flash.events.EventDispatcher;
	import flash.utils.ByteArray;
	
	import org.amqp.BasicConsumer;
	import org.amqp.Command;
	import org.amqp.Connection;
	import org.amqp.ProtocolEvent;
	import org.amqp.headers.BasicProperties;
	import org.amqp.methods.basic.Consume;
	import org.amqp.methods.basic.Deliver;
	import org.amqp.methods.queue.Declare;
	import org.amqp.methods.queue.Purge;
	import org.amqp.methods.queue.PurgeOk;
	import org.amqp.patterns.BasicMessageEvent;
	import org.amqp.patterns.SubscribeClient;

    public class SubscribeClientImpl extends AbstractDelegate implements SubscribeClient, BasicConsumer
    {
        private var topics:HashMap = new HashMap();
        private var topicBuffer:ArrayedQueue = new ArrayedQueue(100);
        private var requestOk:Boolean;
        
        private var dispatcher:EventDispatcher = new EventDispatcher();
    
        public function SubscribeClientImpl(c:Connection) {
			// note: does not work with multiple invocations to a Connection object
			// due to AbstractDelegate's constructor
            super(c);
        }
        
        public function subscribe(key:String, callback:Function):void {
        	if (topics.containsKey(key)) {
        		return;
        	}
        	topics.put(key, {callback:callback, replyQueue:null});
        	
        	buffer(key);
        	
        	if (requestOk) {
        		drainBuffer();
        	}
        }
        
        private function buffer(key:String):void {
			var queuedObj:String = key;
			topicBuffer.enqueue(queuedObj);
        }
        
        private function drainBuffer():void {
        	var bufSize:int = topicBuffer.size;
        	
        	for (var i:int=0; i < bufSize; i++) {
        		setupReplyQueue();
        	}
        }
                
        public function unsubscribe(key:String):void {
        	/*if (key == null) {
        		// unsubscribe all of them
        	}*/
        	
        	// should unsubscription commands be queued?
        	
			if (topics.containsKey(key)) {
				var topic:* = topics.getValue(key);
				var purgeQueue:Purge = new Purge();
				purgeQueue.queue = topic.replyQueue;
				sessionHandler.dispatch(new Command(purgeQueue));
				dispatcher.removeEventListener(key, topic.callback);
				topics.remove(key);
			}
        }
        
        public function onConsumeOk(tag:String):void {
        	var topic:* = topics.getValue(tag);
        	dispatcher.addEventListener(tag, topic.callback);
        }
        
        public function onCancelOk(tag:String):void {}
        
        public function onDeliver(method:Deliver, 
                                  properties:BasicProperties,
                                  body:ByteArray):void {
            var result:* = serializer.deserialize(body);
            dispatcher.dispatchEvent(new BasicMessageEvent(method.consumertag, result));
        }
        
        //public function onPurgeOk(event:ProtocolEvent):void {}
        
		override protected function declareQueue(q:String):void {        	
        	var queue:org.amqp.methods.queue.Declare = new org.amqp.methods.queue.Declare();
        	queue.queue = q;
			queue.autodelete = true;
        	sessionHandler.dispatch(new Command(queue));
        }

        override protected function onRequestOk(event:ProtocolEvent):void {
        	//sessionHandler.addEventListener(new PurgeOk(), onPurgeOk);
        	
            declareExchange(exchange, exchangeType);
            
            requestOk = true;
            drainBuffer();
        }
        
        override protected function onQueueDeclareOk(event:ProtocolEvent):void {
            var replyQueue:String = getReplyQueue(event);
            
            if (!topicBuffer.isEmpty()) {
            	const key:String = topicBuffer.dequeue();
            	
            	var topic:* = topics.getValue(key);
            	topic.replyQueue = replyQueue;
            	topics.put(key, topic);
            	
            	bindQueue(exchange, replyQueue, key);
				
				var consume:Consume = new Consume();
            	consume.queue = replyQueue;
            	consume.noack = true;
            	consume.consumertag = key;
            
            	sessionHandler.register(consume, this);
            }
        }
	}
}