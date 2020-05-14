%% Copyright (c) 2013-2019 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(emqx_kafka_bridge).

-include("emqx_kafka_bridge.hrl").

-include_lib("emqx/include/emqx.hrl").
-include_lib("emqx/include/logger.hrl").

-export([load/1, unload/0]).

%% Client Lifecircle Hooks
-export([on_client_connect/3
  , on_client_connack/4
  , on_client_connected/3
  , on_client_disconnected/4
  , on_client_authenticate/3
  , on_client_check_acl/5
  , on_client_subscribe/4
  , on_client_unsubscribe/4
]).

%% Session Lifecircle Hooks
-export([on_session_created/3
  , on_session_subscribed/4
  , on_session_unsubscribed/4
  , on_session_resumed/3
  , on_session_discarded/3
  , on_session_takeovered/3
  , on_session_terminated/4
]).

%% Message Pubsub Hooks
-export([on_message_publish/2
  , on_message_delivered/3
  , on_message_acked/3
  , on_message_dropped/4
]).

%% Called when the plugin application start
load(Env) ->
  brod_load([Env]),
  emqx:hook('client.connect', {?MODULE, on_client_connect, [Env]}),
  emqx:hook('client.connack', {?MODULE, on_client_connack, [Env]}),
  emqx:hook('client.connected', {?MODULE, on_client_connected, [Env]}),
  emqx:hook('client.disconnected', {?MODULE, on_client_disconnected, [Env]}),
  emqx:hook('client.authenticate', {?MODULE, on_client_authenticate, [Env]}),
  emqx:hook('client.check_acl', {?MODULE, on_client_check_acl, [Env]}),
  emqx:hook('client.subscribe', {?MODULE, on_client_subscribe, [Env]}),
  emqx:hook('client.unsubscribe', {?MODULE, on_client_unsubscribe, [Env]}),
  emqx:hook('session.created', {?MODULE, on_session_created, [Env]}),
  emqx:hook('session.subscribed', {?MODULE, on_session_subscribed, [Env]}),
  emqx:hook('session.unsubscribed', {?MODULE, on_session_unsubscribed, [Env]}),
  emqx:hook('session.resumed', {?MODULE, on_session_resumed, [Env]}),
  emqx:hook('session.discarded', {?MODULE, on_session_discarded, [Env]}),
  emqx:hook('session.takeovered', {?MODULE, on_session_takeovered, [Env]}),
  emqx:hook('session.terminated', {?MODULE, on_session_terminated, [Env]}),
  emqx:hook('message.publish', {?MODULE, on_message_publish, [Env]}),
  emqx:hook('message.delivered', {?MODULE, on_message_delivered, [Env]}),
  emqx:hook('message.acked', {?MODULE, on_message_acked, [Env]}),
  emqx:hook('message.dropped', {?MODULE, on_message_dropped, [Env]}).

%%--------------------------------------------------------------------
%% Client Lifecircle Hooks
%%--------------------------------------------------------------------

on_client_connect(ConnInfo = #{clientid := ClientId}, Props, _Env) ->
  io:format("Client(~s) connect, ConnInfo: ~p, Props: ~p~n",
    [ClientId, ConnInfo, Props]),
  {ok, Props}.

on_client_connack(ConnInfo = #{clientid := ClientId}, Rc, Props, _Env) ->
  io:format("Client(~s) connack, ConnInfo: ~p, Rc: ~p, Props: ~p~n",
    [ClientId, ConnInfo, Rc, Props]),
  {ok, Props}.

% on_client_connected(ClientInfo = #{clientid := ClientId}, ConnInfo, _Env) ->
%   io:format("Client(~s) connected, ClientInfo:~n~p~n, ConnInfo:~n~p~n",
%     [ClientId, ClientInfo, ConnInfo]);

on_client_connected(ClientInfo = #{clientid := ClientId, username := Username, peerhost := Peerhost}, ConnInfo, _Env) ->
    io:format("Client(~s) connected, ClientInfo:~n~p~n, ConnInfo:~n~p~n",
      [ClientId, ClientInfo, ConnInfo]), 
    Params = #{ action => connected,
            clientid => ClientId,
            username => Username,
            ipaddress => iolist_to_binary(ntoa(Peerhost)),
            keepalive => maps:get(keepalive, ConnInfo),
            proto_ver => maps:get(proto_ver, ConnInfo),
            connected_at => maps:get(connected_at, ConnInfo),
            tm => calendar:local_time()},
    Kafka = proplists:get_value(bridges, _Env),
    OnMessagePublishTopic = proplists:get_value(on_message_publish_topic, Kafka),
    produce_kafka_message(list_to_binary(OnMessagePublishTopic), Params, ClientId, _Env),
    ok;

on_client_connected(#{}, _ConnInfo, _Env) ->
    ok.

% on_client_disconnected(ClientInfo = #{clientid := ClientId}, ReasonCode, ConnInfo, _Env) ->
%   io:format("Client(~s) disconnected due to ~p, ClientInfo:~n~p~n, ConnInfo:~n~p~n",
%     [ClientId, ReasonCode, ClientInfo, ConnInfo]).


on_client_disconnected(ClientInfo = #{clientid := ClientId}, {shutdown, Reason}, ConnInfo, Env) when is_atom(Reason) ->
    io:format("Client(~s) disconnected due to ~p, ClientInfo:~n~p~n, ConnInfo:~n~p~n",
      [ClientId, Reason, ClientInfo, ConnInfo]),
    on_client_disconnected(ClientInfo, Reason, ConnInfo, Env);

on_client_disconnected(#{clientid := ClientId, username := Username}, Reason, ConnInfo, _Env) ->
    Params = #{ action => disconnected,
            clientid => ClientId,
            username => Username,
            code => printable(Reason),
            tm => calendar:local_time()},
    Kafka = proplists:get_value(bridges, _Env),
    OnMessagePublishTopic = proplists:get_value(on_message_publish_topic, Kafka),
    produce_kafka_message(list_to_binary(OnMessagePublishTopic), Params, ClientId, _Env),
    ok.

printable(Term) when is_atom(Term); is_binary(Term) ->
    Term;
printable(Term) when is_tuple(Term) ->
    iolist_to_binary(io_lib:format("~p", [Term])).

on_client_authenticate(_ClientInfo = #{clientid := ClientId}, Result, _Env) ->
  io:format("Client(~s) authenticate, Result:~n~p~n", [ClientId, Result]),
  {ok, Result}.

on_client_check_acl(_ClientInfo = #{clientid := ClientId}, Topic, PubSub, Result, _Env) ->
  io:format("Client(~s) check_acl, PubSub:~p, Topic:~p, Result:~p~n",
    [ClientId, PubSub, Topic, Result]),
  {ok, Result}.

on_client_subscribe(#{clientid := ClientId}, _Properties, TopicFilters, _Env) ->
  io:format("Client(~s) will subscribe: ~p~n", [ClientId, TopicFilters]),
  {ok, TopicFilters}.

on_client_unsubscribe(#{clientid := ClientId}, _Properties, TopicFilters, _Env) ->
  io:format("Client(~s) will unsubscribe ~p~n", [ClientId, TopicFilters]),
  {ok, TopicFilters}.

%%--------------------------------------------------------------------
%% Session Lifecircle Hooks
%%--------------------------------------------------------------------

on_session_created(#{clientid := ClientId}, SessInfo, _Env) ->
  io:format("Session(~s) created, Session Info:~n~p~n", [ClientId, SessInfo]).

on_session_subscribed(#{clientid := ClientId}, Topic, SubOpts, _Env) ->
  io:format("Session(~s) subscribed ~s with subopts: ~p~n", [ClientId, Topic, SubOpts]).

on_session_unsubscribed(#{clientid := ClientId}, Topic, Opts, _Env) ->
  io:format("Session(~s) unsubscribed ~s with opts: ~p~n", [ClientId, Topic, Opts]).

on_session_resumed(#{clientid := ClientId}, SessInfo, _Env) ->
  io:format("Session(~s) resumed, Session Info:~n~p~n", [ClientId, SessInfo]).

on_session_discarded(_ClientInfo = #{clientid := ClientId}, SessInfo, _Env) ->
  io:format("Session(~s) is discarded. Session Info: ~p~n", [ClientId, SessInfo]).

on_session_takeovered(_ClientInfo = #{clientid := ClientId}, SessInfo, _Env) ->
  io:format("Session(~s) is takeovered. Session Info: ~p~n", [ClientId, SessInfo]).

on_session_terminated(_ClientInfo = #{clientid := ClientId}, Reason, SessInfo, _Env) ->
  io:format("Session(~s) is terminated due to ~p~nSession Info: ~p~n",
    [ClientId, Reason, SessInfo]).

%%--------------------------------------------------------------------
%% Message PubSub Hooks
%%--------------------------------------------------------------------


on_message_publish(Message = #message{topic = <<"$SYS/", _/binary>>}, _Env) ->
    {ok, Message};

on_message_publish(Message = #message{topic = Topic, flags = #{retain := Retain}}, _Env) ->
    {FromClientId, FromUsername, Peerhost} = format_from(Message),
    Params = #{
            action => published,
            clientid => FromClientId,
            username => FromUsername,
            ipaddress => Peerhost,
            topic => Message#message.topic,
            qos => Message#message.qos,
            payload => encode_payload(Message#message.payload),
            ts => Message#message.timestamp,
            tm => calendar:local_time()},
    Kafka = proplists:get_value(bridges, _Env),
    %OnMessagePublishTopic = proplists:get_value(on_message_publish_topic, Kafka),
    OnMessagePublishTopic = proplists:get_value(topic, Kafka),
    produce_kafka_message(list_to_binary(OnMessagePublishTopic), Params, FromClientId, _Env),
    {ok, Message}.

%% Transform message and return
% on_message_publish(Message = #message{topic = <<"$SYS/", _/binary>>}, _Env) ->
%   {ok, Message};

% on_message_publish(Message, Env) ->
%   #message{id = Id, qos = QoS, topic = Topic, from = From, flags = Flags, headers = Headers, payload = Payload, timestamp = Timestamp} = Message,
%   Msg = [
%     {qos, QoS},
%     {topic, Topic},
%     {from, From},
% %%    {flags, Flags},
% %%    {headers, Headers},
%     {payload, Payload},
%     {timestamp, Timestamp}
%   ],
%   Kafka = proplists:get_value(bridges, Env),
%   OnMessagePublishTopic = proplists:get_value(on_message_publish_topic, Kafka),
%   produce_kafka_message(list_to_binary(OnMessagePublishTopic), Msg, From, Env),
%   {ok, Message}.

on_message_dropped(#message{topic = <<"$SYS/", _/binary>>}, _By, _Reason, _Env) ->
  ok;
on_message_dropped(Message, _By = #{node := Node}, Reason, _Env) ->
  io:format("Message dropped by node ~s due to ~s: ~s~n",
    [Node, Reason, emqx_message:format(Message)]).

on_message_delivered(_ClientInfo = #{clientid := ClientId}, Message, _Env) ->
  io:format("Message delivered to client(~s): ~s~n",
    [ClientId, emqx_message:format(Message)]),
  {ok, Message}.

on_message_acked(_ClientInfo = #{clientid := ClientId}, Message, _Env) ->
  io:format("Message acked by client(~s): ~s~n",
    [ClientId, emqx_message:format(Message)]).

%% Called when the plugin application stop
unload() ->
  brod_unload(),
  emqx:unhook('client.connect', {?MODULE, on_client_connect}),
  emqx:unhook('client.connack', {?MODULE, on_client_connack}),
  emqx:unhook('client.connected', {?MODULE, on_client_connected}),
  emqx:unhook('client.disconnected', {?MODULE, on_client_disconnected}),
  emqx:unhook('client.authenticate', {?MODULE, on_client_authenticate}),
  emqx:unhook('client.check_acl', {?MODULE, on_client_check_acl}),
  emqx:unhook('client.subscribe', {?MODULE, on_client_subscribe}),
  emqx:unhook('client.unsubscribe', {?MODULE, on_client_unsubscribe}),
  emqx:unhook('session.created', {?MODULE, on_session_created}),
  emqx:unhook('session.subscribed', {?MODULE, on_session_subscribed}),
  emqx:unhook('session.unsubscribed', {?MODULE, on_session_unsubscribed}),
  emqx:unhook('session.resumed', {?MODULE, on_session_resumed}),
  emqx:unhook('session.discarded', {?MODULE, on_session_discarded}),
  emqx:unhook('session.takeovered', {?MODULE, on_session_takeovered}),
  emqx:unhook('session.terminated', {?MODULE, on_session_terminated}),
  emqx:unhook('message.publish', {?MODULE, on_message_publish}),
  emqx:unhook('message.delivered', {?MODULE, on_message_delivered}),
  emqx:unhook('message.acked', {?MODULE, on_message_acked}),
  emqx:unhook('message.dropped', {?MODULE, on_message_dropped}).

brod_load(_Env) ->
  {ok, _} = application:ensure_all_started(gproc),
  {ok, _} = application:ensure_all_started(brod),
  {ok, Kafka} = application:get_env(?MODULE, bridges),
  KafkaBootstrapHost = proplists:get_value(bootstrap_broker_host, Kafka),
  KafkaBootstrapPort = proplists:get_value(bootstrap_broker_port, Kafka),
  KafkaBootstrapEndpoints = [{KafkaBootstrapHost, KafkaBootstrapPort}],
  ClientConfig = [{auto_start_producers, true}, {default_producer_config, []}, {reconnect_cool_down_seconds, 10}, {reconnect_cool_down_seconds, 10}],
  ok = brod:start_client(KafkaBootstrapEndpoints, brod_client_1, ClientConfig),
  % emqx_metrics:inc('bridge.kafka.connected'),
  io:format("load brod with ~p~n", [KafkaBootstrapEndpoints]).

brod_unload() ->
  application:stop(brod),
  % emqx_metrics:inc('bridge.kafka.disconnected'),
  io:format("unload brod~n"),
  ok.

getPartition(Key) ->
  {ok, Kafka} = application:get_env(?MODULE, bridges),
  PartitionNum = proplists:get_value(producer_partition, Kafka),
  <<Fix:120, Match:8>> = crypto:hash(md5, Key),
  abs(Match) rem PartitionNum.

produce_kafka_message(Topic, Message, ClientId, Env) ->
  Key = iolist_to_binary(ClientId),
  Partition = getPartition(Key),
  JsonStr = jsx:encode(Message),
  Kafka = proplists:get_value(bridges, Env),
  IsAsyncProducer = proplists:get_value(is_async_producer, Kafka),
  if
    IsAsyncProducer == false ->
      brod:produce_sync(brod_client_1, Topic, Partition, ClientId, JsonStr);
    true ->
      brod:produce_no_ack(brod_client_1, Topic, Partition, ClientId, JsonStr)
%%      brod:produce(brod_client_1, Topic, Partition, ClientId, JsonStr)
  end,
  ok.
  
format_from(#message{from = ClientId, headers = #{peerhost :=PeerHost, username := Username}}) ->
    {a2b(ClientId), a2b(Username), iolist_to_binary(ntoa(a2b(PeerHost)))};
format_from(#message{from = ClientId, headers = _HeadersNoUsername}) ->
    {a2b(ClientId), <<"undefined">>, <<"undefined">>}.

encode_payload(Payload) ->
    encode_payload(Payload, application:get_env(?APP, encode, undefined)).

encode_payload(Payload, base62) -> emqx_base62:encode(Payload);
encode_payload(Payload, base64) -> base64:encode(Payload);
encode_payload(Payload, _) -> Payload.

a2b(A) when is_atom(A) -> erlang:atom_to_binary(A, utf8);
a2b(A) -> A.

ntoa({0,0,0,0,0,16#ffff,AB,CD}) ->
    inet_parse:ntoa({AB bsr 8, AB rem 256, CD bsr 8, CD rem 256});
ntoa(IP) ->
    inet_parse:ntoa(IP).