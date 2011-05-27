%%%-------------------------------------------------------------------
%%% @author Karl Anderson <karl@2600hz.org>
%%% @copyright (C) 2011, Karl Anderson
%%% @doc
%%%
%%% @end
%%% Created : 22 Feb 2011 by Karl Anderson <karl@2600hz.org>
%%%-------------------------------------------------------------------
-module(cf_call_forward).

-include("../callflow.hrl").

-export([handle/2]).

-import(cf_call_command, [b_bridge/6, wait_for_bridge/1, wait_for_unbridge/0, set/3, b_fetch/2]).

-record(prompts, {
           has_been_enabled = <<"/system_media/custom-your_calls_are_now_forwarded_to">>
          ,has_been_disabled = <<"/system_media/custom-call_forwarding_is_now_disabled">>
          ,feature_not_avaliable = <<"/system_media/custom-feature_not_avaliable_on_this_line">>
          ,enter_forwarding_number = <<"/system_media/custom-enter_the_number_to_forward_to">>
          ,main_menu = <<"/system_media/custom-call_forwarding_menu">>
          ,to_enable_cf = <<"/system_media/custom-to_enable_cf_press">>
          ,to_disable_cf = <<"/system_media/custom-to_disable_cf_press">>
          ,to_change_number = <<"/system_media/custom-to_change_the_number_to_forward_to">>
         }).

-record(keys, {
           menu_toggle_cf = <<"1">>
          ,menu_change_number = <<"2">>
         }).

-record(callfwd, {
           prompts = #prompts{}
          ,keys = #keys{}
          ,doc_id = undefined
          ,enabled = false
          ,number = <<>>
          ,require_keypress = true
          ,keep_caller_id = true              
         }).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Entry point for this module, attempts to call an endpoint as defined
%% in the Data payload.  Returns continue if fails to connect or 
%% stop when successfull.
%% @end
%%--------------------------------------------------------------------
-spec(handle/2 :: (Data :: json_object(), Call :: #cf_call{}) -> tuple(stop | continue)).
handle(Data, #cf_call{cf_pid=CFPid}=Call) ->
    case get_call_forward(Call) of
        {error, #callfwd{prompts=Prompts}} ->
            cf_call_command:b_play(Prompts#prompts.feature_not_avaliable, Call),
            CFPid ! {stop};
        CF ->        
            cf_call_command:answer(Call),
            CF1 = case wh_json:get_value(<<"action">>, Data) of 
                           <<"activate">> -> cf_activate(CF, Call);       %% Support for NANPA *72
                           <<"deactivate">> -> cf_deactivate(CF, Call);   %% Support for NANPA *73
                           <<"update">> -> cf_update_number(CF, Call);    %% Support for NANPA *56
                           <<"toggle">> -> cf_toggle(CF, Call);
                           <<"menu">> -> cf_menu(CF, Call)
                       end,
            update_callfwd(CF1, Call),
            CFPid ! {continue}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function provides a menu with the call forwarding options
%% @end
%%--------------------------------------------------------------------
-spec(cf_menu/2 :: (CF :: #callfwd{}, Call :: #cf_call{}) -> no_return()).
cf_menu(#callfwd{prompts=#prompts{main_menu=MainMenu, to_enable_cf=ToEnableCF, to_disable_cf=ToDisableCF, to_change_number=ToChangeNum}
                  ,keys=#keys{menu_toggle_cf=Toggle, menu_change_number=ChangeNum}}=CF, Call) ->
    TogglePrompt = case CF#callfwd.enabled of
                       true -> ToDisableCF;
                       false -> ToEnableCF
                   end,
    cf_call_command:audio_macro([
                                  {play, MainMenu}
                                 
                                 ,{play, TogglePrompt}
                                 ,{say,  Toggle}
                                 
                                 ,{play, ToChangeNum}
                                 ,{say,  ChangeNum}
                                ], Call),
    {ok, Digit} = cf_call_command:wait_for_dtmf(30000),
    _ = cf_call_command:flush(Call),
    case Digit of
	Toggle ->
            CF1 = cf_toggle(CF, Call),
            {ok, _} = update_callfwd(CF1, Call),
            cf_menu(CF1, Call);
        ChangeNum ->
            CF1 = cf_update_number(CF, Call),
            {ok, _} = update_callfwd(CF1, Call),
	    cf_menu(CF1, Call);            
	_ ->
	    cf_menu(CF, Call)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will update the call forwarding enabling it if it is
%% not, and disabling it if it is
%% @end
%%--------------------------------------------------------------------
-spec(cf_toggle/2 :: (CF :: #callfwd{}, Call :: #cf_call{}) -> #callfwd{}).
cf_toggle(#callfwd{enabled=false}=CF, Call) ->
    cf_activate(CF, Call);
cf_toggle(#callfwd{enabled=true}=CF, Call) ->
    cf_deactivate(CF, Call).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will udpate the call forwarding object on the owner
%% document to enable call forwarding
%% @end
%%--------------------------------------------------------------------
-spec(cf_activate/2 :: (CF :: #callfwd{}, Call :: #cf_call{}) -> #callfwd{}).
cf_activate(#callfwd{number = <<>>}=CF, Call) ->
    cf_activate(cf_update_number(CF, Call), Call);
cf_activate(#callfwd{number=Number, prompts=Prompts}=CF, Call) ->
    cf_call_command:play(Prompts#prompts.has_been_enabled, Call),
    cf_call_command:b_say(Number, Call),
    CF#callfwd{enabled=true}.                

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will udpate the call forwarding object on the owner
%% document to disable call forwarding
%% @end
%%--------------------------------------------------------------------
-spec(cf_deactivate/2 :: (CF :: #callfwd{}, Call :: #cf_call{}) -> #callfwd{}).
cf_deactivate(#callfwd{prompts=Prompts}=CF, Call) ->
    cf_call_command:b_play(Prompts#prompts.has_been_disabled, Call),
    CF#callfwd{enabled=false}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will udpate the call forwarding object on the owner
%% document with a new number
%% @end
%%--------------------------------------------------------------------
-spec(cf_update_number/2 :: (CF :: #callfwd{}, Call :: #cf_call{}) -> #callfwd{}).
cf_update_number(#callfwd{prompts=Prompts}=CF, Call) ->
    {ok, Number} = cf_call_command:b_play_and_collect_digits(<<"3">>, <<"20">>, Prompts#prompts.enter_forwarding_number, <<"1">>, <<"8000">>, Call),
    CF#callfwd{number=Number}.
    
%%--------------------------------------------------------------------
%% @private
%% @doc
%% This is a helper function to update a document, and corrects the
%% rev tag if the document is in conflict
%% @end
%%--------------------------------------------------------------------
-spec(update_callfwd/2 :: (CF :: #callfwd{}, Call :: #cf_call{}) -> tuple(ok, json_object())|tuple(error, atom())).
update_callfwd(#callfwd{doc_id=Id, enabled=Enabled, number=Num, require_keypress=RK, keep_caller_id=KCI}=CF
               , #cf_call{account_db=Db}=Call) ->    
    {ok, JObj} = couch_mgr:open_doc(Db, Id),
    CF1 = {struct, [
                     {<<"enabled">>, Enabled}
                    ,{<<"number">>, Num}
                    ,{<<"require_keypress">>, RK}
                    ,{<<"keep_caller_id">>, KCI}
                   ]},
    case couch_mgr:save_doc(Db, wh_json:set_value(<<"call_forward">>, CF1, JObj)) of 
        {error, conflict} ->
            update_callfwd(CF, Call);
        {ok, JObj1} ->
            {ok, JObj1};
        {error, _}=E ->
            E
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will load the call forwarding record
%% @end
%%--------------------------------------------------------------------
-spec(get_call_forward/1 :: (Call :: #cf_call{}) -> #callfwd{}|tuple(error, #callfwd{})).
get_call_forward(#cf_call{authorizing_id=Id, account_db=Db}) ->
    case couch_mgr:get_results(Db, <<"devices/listing_with_owner">>, [{<<"include_docs">>, true}, {<<"key">>, Id}]) of     
        {ok, [JObj]} ->
            Owner = wh_json:get_value(<<"doc">>, JObj),
            #callfwd{
                       doc_id = wh_json:get_value(<<"_id">>, Owner, wh_json:get_value(<<"id">>, JObj))
                      ,enabled = whistle_util:is_true(wh_json:get_value([<<"call_forward">>, <<"enabled">>], Owner, false))
                      ,number = wh_json:get_value([<<"call_forward">>, <<"number">>], Owner, <<>>)
                      ,require_keypress = whistle_util:is_true(wh_json:get_value([<<"call_forward">>, <<"require_keypress">>], Owner, true))
                      ,keep_caller_id = whistle_util:is_true(wh_json:get_value([<<"call_forward">>, <<"keep_caller_id">>], Owner, true))
                    };
        {ok, []} ->
            {error, #callfwd{}};
        {error, _} ->
            {error, #callfwd{}}
    end.