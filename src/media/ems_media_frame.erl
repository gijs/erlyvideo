%%% @author     Max Lapshin <max@maxidoors.ru> [http://erlyvideo.org]
%%% @copyright  2009-2010 Max Lapshin
%%% @doc        Erlyvideo media clients handling
%%% @reference  See <a href="http://erlyvideo.org/" target="_top">http://erlyvideo.org/</a> for more information
%%% @end
%%%
%%% This file is part of erlyvideo.
%%% 
%%% erlyvideo is free software: you can redistribute it and/or modify
%%% it under the terms of the GNU General Public License as published by
%%% the Free Software Foundation, either version 3 of the License, or
%%% (at your option) any later version.
%%%
%%% erlyvideo is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%%% GNU General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with erlyvideo.  If not, see <http://www.gnu.org/licenses/>.
%%%
%%%---------------------------------------------------------------------------------------
-module(ems_media_frame).
-author('Max Lapshin <max@maxidoors.ru>').

-include_lib("erlmedia/include/video_frame.hrl").
-include("../include/ems_media.hrl").
-include("../log.hrl").
-include("ems_media_client.hrl").

-export([transcode/2, send_frame/2]).

-define(TIMEOUT, 1000).

transcode(#video_frame{} = Frame, #ems_media{transcoder = Transcoder, trans_state = State} = Media) when Transcoder =/= undefined ->
  {ok, Frames, State1} = Transcoder:transcode(Frame, State),
  {Media#ems_media{trans_state = State1}, Frames};
  

transcode(#video_frame{content = audio, codec = Codec} = Frame, Media) when Codec == pcma orelse 
                                                                     % Codec == pcm orelse
                                                                     Codec == g726_16 orelse
                                                                     % Codec == pcm_le orelse
                                                                     % Codec == mp3 orelse
                                                                     Codec == pcmu ->
  case erlang:function_exported(ems_sound, adapt_sound, 1) of
    true -> 
      {Media, ems_sound:adapt_sound(Frame)};
    _ ->
      {Media, undefined}
  end;  

transcode(Frame, Media) ->
  {Media, Frame}.



send_frame(Frame, Media) ->
  shift_dts(Frame, Media).

shift_dts(#video_frame{} = Frame, #ems_media{last_dts = undefined} = Media) ->
  shift_dts(Frame, Media#ems_media{last_dts = 0});

shift_dts(#video_frame{dts = undefined} = Frame, #ems_media{last_dts = LastDTS} = Media) ->
  handle_shifted_frame(Frame#video_frame{dts = LastDTS, pts = LastDTS}, Media);

shift_dts(#video_frame{dts = DTS} = Frame, #ems_media{ts_delta = undefined, last_dts = LastDTS} = Media) ->
  ?D({"New instance of stream", LastDTS, DTS, LastDTS - DTS}),
  ems_event:stream_started(proplists:get_value(host,Media#ems_media.options), Media#ems_media.name, self(), Media#ems_media.options),
  shift_dts(Frame, Media#ems_media{ts_delta = LastDTS - DTS}); %% Lets glue new instance of stream to old one

shift_dts(#video_frame{dts = DTS, pts = PTS} = Frame, #ems_media{ts_delta = Delta} = Media) ->
  % ?D({Frame#video_frame.content, round(Frame#video_frame.dts), round(Delta), round(DTS + Delta)}),
  handle_shifted_frame(Frame#video_frame{dts = DTS + Delta, pts = PTS + Delta}, Media).

handle_shifted_frame(#video_frame{dts = DTS} = Frame, 
  #ems_media{format = Format, storage = Storage, frame_number = Number} = Media) ->
  % ?D({Frame#video_frame.content, Number, Frame#video_frame.flavor, Frame#video_frame.dts}),
  Media1 = start_on_keyframe(Frame, Media),
  Storage1 = save_frame(Format, Storage, Frame),
  handle_config(Frame, Media1#ems_media{storage = Storage1, last_dts = DTS, frame_number = Number + 1}).

reply_with_decoder_config(#ems_media{frame_number = Number, audio_config = A, video_config = V,
  waiting_for_config = Waiting} = Media) 
  when length(Waiting) > 0 andalso ((A =/= undefined andalso V =/= undefined) orelse (Number >= ?WAIT_FOR_CONFIG)) ->
  ?D({"Received live config replying to", Number, Waiting}),
  Reply = {ok, [{audio,A},{video,V}]},
  [gen_server:reply(From, Reply) || From <- Waiting],
  Media#ems_media{waiting_for_config = []};

reply_with_decoder_config(Media) ->
  % ?D({ignoring, Media#ems_media.frame_number}),
  Media.



handle_config(#video_frame{content = video, body = Config}, #ems_media{video_config = #video_frame{body = Config}} = Media) -> 
  {noreply, Media, ?TIMEOUT};

handle_config(#video_frame{content = audio, body = Config}, #ems_media{audio_config = #video_frame{body = Config}} = Media) -> 
  {noreply, Media, ?TIMEOUT};

handle_config(#video_frame{content = video, flavor = config} = Config, #ems_media{} = Media) ->
  handle_frame(Config, Media#ems_media{video_config = Config});

handle_config(#video_frame{content = audio, flavor = config} = Config, #ems_media{} = Media) -> 
  handle_frame(Config, Media#ems_media{audio_config = Config});

handle_config(Frame, Media) ->
  handle_frame(Frame, Media).


handle_frame(#video_frame{content = Content} = Frame, #ems_media{module = M, clients = Clients} = Media) ->
  Media1 = reply_with_decoder_config(Media),
  case M:handle_frame(Frame, Media1) of
    {reply, F, Media2} ->
      case Content of
        audio -> ems_media_clients:send_frame(F, Clients, starting);
        _ -> ok
      end,
      ems_media_clients:send_frame(F, Clients, active),
      {noreply, Media2, ?TIMEOUT};
    {noreply, Media2} ->
      {noreply, Media2, ?TIMEOUT};
    {stop, Reason, Media2} ->
      {stop, Reason, Media2}
  end.


save_frame(undefined, Storage, _) ->
  Storage;

save_frame(Format, Storage, Frame) ->
  case Format:write_frame(Frame, Storage) of
    {ok, Storage1} -> Storage1;
    _ -> Storage
  end.

start_on_keyframe(#video_frame{content = video, flavor = keyframe, dts = DTS} = _F, 
                  #ems_media{clients = Clients, video_config = V} = M) ->
  Starting = ems_media_clients:select_by_state(Clients, starting),
  Meta = ems_media:metadata_frame(M),
  lists:foreach(fun(#client{consumer = Client, stream_id = StreamId}) ->
    case Meta of
      undefined -> ok;
      _ -> Client ! Meta#video_frame{dts = DTS, pts = DTS, stream_id = StreamId}
    end,
    
    %
    % We need to send video config only here, because audio config is sent earlier
    (catch Client ! V#video_frame{dts = DTS, pts = DTS, stream_id = StreamId})
  end, Starting),
  Clients2 = ems_media_clients:mass_update_state(Clients, starting, active),
  M#ems_media{clients = Clients2};


start_on_keyframe(_, Media) ->
  Media.
