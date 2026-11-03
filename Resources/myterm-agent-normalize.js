ObjC.import('Foundation');

function run(args) {
    const agent = args[0];
    let activity = args[1];
    const data = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;
    const input = ObjC.unwrap($.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding));
    let p;
    try { p = JSON.parse(input); } catch (_) { return '{}'; }
    if (!p || typeof p !== 'object' || Array.isArray(p)) return '{}';
    const result = {};
    if (agent === 'grok') {
        if (p.subagentType || p.subagent_type || p.agent_id) return '{}';
        const event = String(p.hookEventName || p.hook_event_name || '').replace(/_/g, '').toLowerCase();
        const notification = p.notificationType || p.notification_type;
        if (event === 'stop' && (p.reason === 'shutdown' || p.reason === 'channel_closed')) return '{}';
        if (activity === 'awaiting_input' && notification !== 'permission_prompt' && notification !== 'elicitation_dialog') return '{}';
        result.session_id = p.sessionId || p.session_id;
        result.cwd = p.cwd || p.workspaceRoot;
        result.turn = p.promptId || p.prompt_id;
        result.turn_start = event === 'userpromptsubmit';
        // Parent-facing notifications describe visible dialogs; inherited Claude hooks
        // are suppressed separately so a notification is reported under one identity.
        if (activity === 'awaiting_input') {
            result.tool_key = notification === 'elicitation_dialog' ? 'grok-question' : 'grok-permission';
        } else if (event === 'posttooluse' || event === 'posttoolusefailure') {
            result.tool_key = (p.toolName || p.tool_name) === 'ask_user_question' ? 'grok-question' : 'grok-permission';
        }
    } else if (agent === 'antigravity') {
        if (p.agent_id || p.subagentType || p.subagent_type || p.parentConversationId || p.parent_conversation_id) return '{}';
        result.session_id = p.conversationId || p.conversation_id || p.session_id;
        result.cwd = p.cwd || (Array.isArray(p.workspacePaths) ? p.workspacePaths[0] : undefined);
        result.session_title = p.conversation_title;
        if (activity === 'finished' && p.fullyIdle === false) activity = 'working';
        if (activity === 'status') {
            result.snapshot = true;
            if (p.tool_confirmation_pending === true || p.agent_state === 'reviewing') activity = 'awaiting_input';
            else if (p.agent_state === 'working' || p.agent_state === 'tool_use') activity = 'working';
            else if (p.agent_state === 'idle' || p.agent_state === 'error') activity = 'finished';
            else activity = 'title';
            result.tool_key = 'antigravity-permission';
        } else if (p.toolCall && p.toolCall.name === 'ask_question') {
            result.tool_key = 'antigravity-question';
        }
    } else return '{}';
    result.activity = activity;
    if (typeof result.session_title === 'string') {
        result.session_title = result.session_title.replace(/[\u0000-\u001f\u007f-\u009f]/g, '').slice(0, 128);
    } else delete result.session_title;
    return JSON.stringify(result);
}
