-module(charge_verification_test).
-include_lib("eunit/include/eunit.hrl").
-include("include/hb.hrl").

%% @doc Test to reproduce the charge message verification issue
%% between normal state and TEE + non-volatile state using LMDB
charge_linkification_verification_test() ->
    %% Start the hb application
    application:ensure_all_started(hb),

    %% Create test wallets
    UserWallet = ar_wallet:new(),
    NodeWallet = ar_wallet:new(),

    %% Step 1: Create a user request (like what comes from user)
    BaseRequest = #{
        <<"path">> => <<"test-action">>,
        <<"data">> => <<"some test data">>,
        <<"user-id">> => hb_util:human_id(ar_wallet:to_address(UserWallet))
    },

    %% Sign the user request
    SignedRequest = hb_message:commit(BaseRequest, UserWallet),
    RequestID = hb_message:id(SignedRequest, all),

    ?event({test, signed_request_id, hb_util:human_id(RequestID)}),

    %% Step 2: Create charge message like dev_p4.erl does
    ChargeMessage = #{
        <<"path">> => <<"charge">>,
        <<"quantity">> => 100,
        <<"account">> => hb_util:human_id(ar_wallet:to_address(UserWallet)),
        <<"recipient">> => hb_util:human_id(ar_wallet:to_address(NodeWallet)),
        <<"request">> => SignedRequest  % This embeds the full request
    },

    %% Sign the charge message (node signs the charge)
    SignedCharge = hb_message:commit(ChargeMessage, NodeWallet),
    ChargeID = hb_message:id(SignedCharge, all),

    ?event({test, signed_charge_id, hb_util:human_id(ChargeID)}),

    %% Step 3: Verify original works
    OriginalVerification = hb_message:verify(SignedCharge),
    ?assertEqual(true, OriginalVerification),
    ?event({test, original_verification, OriginalVerification}),

    %% Step 4: Set up LMDB store (simulating TEE + non-volatile)
    % TestDir = "/tmp/test_lmdb_" ++ integer_to_list(erlang:system_time()),

    StoreOpts = hb_http_server:get_opts(#{
        http_server => hb_util:human_id(ar_wallet:to_address(hb:wallet()))
    }),

    % ?event({test, initializing_lmdb_store, TestDir}),

    %% Step 5: Write message to LMDB (this should linkify embedded request)
    {ok, _Path} = hb_cache:write(SignedCharge, StoreOpts),
    ?event({test, wrote_to_lmdb}),

    %% Step 6: Read it back from LMDB
    {ok, RetrievedCharge} = hb_cache:read(hb_util:human_id(ChargeID), StoreOpts),
    ?event({test, read_from_lmdb}),

    %% Step 7: Check structural differences
    OriginalKeys = lists:sort(maps:keys(maps:without([<<"commitments">>], SignedCharge))),
    RetrievedKeys = lists:sort(maps:keys(maps:without([<<"commitments">>], RetrievedCharge))),

    ?event({test, original_keys, OriginalKeys}),
    ?event({test, retrieved_keys, RetrievedKeys}),

    %% Look for linkification evidence
    LinkKeys = lists:filter(
        fun(Key) ->
            case binary:match(Key, <<"+link">>) of
                nomatch -> false;
                _ -> true
            end
        end,
        RetrievedKeys
    ),

    ?event({test, found_link_keys, LinkKeys}),

    %% Check if request became request+link
    HasDirectRequest = maps:is_key(<<"request">>, RetrievedCharge),
    HasLinkedRequest = maps:is_key(<<"request+link">>, RetrievedCharge),

    ?event({test, has_direct_request, HasDirectRequest}),
    ?event({test, has_linked_request, HasLinkedRequest}),

    %% Step 8: THE CRITICAL TEST - verify retrieved message
    RetrievedVerification = hb_message:verify(RetrievedCharge, all, StoreOpts),
    ?event({test, retrieved_verification, RetrievedVerification}),

    %% Step 9: Test different verification contexts
    %% Simulate different linkify modes like in TEE vs normal
    VerifyOptsDiscard = StoreOpts#{linkify_mode => discard},
    VerifyOptsOffload = StoreOpts#{linkify_mode => offload},

    VerificationDiscard = try
        hb_message:verify(RetrievedCharge, all, VerifyOptsDiscard)
    catch
        ErrorClass:ErrorReason:ErrorStack ->
            ?event({test, verification_discard_error, {ErrorClass, ErrorReason, ErrorStack}}),
            {error, {ErrorClass, ErrorReason}}
    end,

    VerificationOffload = try
        hb_message:verify(RetrievedCharge, all, VerifyOptsOffload)
    catch
        ErrorClass2:ErrorReason2:ErrorStack2 ->
            ?event({test, verification_offload_error, {ErrorClass2, ErrorReason2, ErrorStack2}}),
            {error, {ErrorClass2, ErrorReason2}}
    end,

    ?event({test, verification_with_discard, VerificationDiscard}),
    ?event({test, verification_with_offload, VerificationOffload}),

    %% Step 10: Clean up
    % try
    %     os:cmd("rm -rf " ++ TestDir)
    % catch
    %     _:_ -> ok
    % end,

    %% Assertions to check our hypothesis
    ?assertEqual(true, OriginalVerification),

    %% If our hypothesis is correct, the retrieved message should fail verification
    %% because the +link key contains just an ID instead of the full request content
    case {HasLinkedRequest, RetrievedVerification} of
        {true, false} ->
            ?event({test, hypothesis_confirmed, linkification_breaks_verification});
        {true, true} ->
            ?event({test, hypothesis_wrong, linkification_preserves_verification});
        {false, _} ->
            ?event({test, no_linkification_occurred})
    end,

    %% Return results for analysis
    #{
        original_verification => OriginalVerification,
        retrieved_verification => RetrievedVerification,
        has_linked_request => HasLinkedRequest,
        verification_discard => VerificationDiscard,
        verification_offload => VerificationOffload,
        link_keys => LinkKeys
    }.