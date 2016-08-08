module dlangbot.github;

import dlangbot.comment;
import dlangbot.issue;
import vibe.core.log;
import vibe.data.json;
import vibe.http.common : HTTPMethod;
import vibe.http.client : requestHTTP;
import vibe.http.server : HTTPServerRequest, HTTPServerResponse;

string githubAuth, hookSecret;

//==============================================================================
// Github hook
//==============================================================================

auto getSignature(string data)
{
    import std.digest.digest, std.digest.hmac, std.digest.sha;
    import std.string : representation;

    auto hmac = HMAC!SHA1(hookSecret.representation);
    hmac.put(data.representation);
    return hmac.finish.toHexString!(LetterCase.lower);
}

Json verifyRequest(string signature, string data)
{
    import std.exception : enforce;
    import std.string : chompPrefix;

    enforce(getSignature(data) == signature.chompPrefix("sha1="),
            "Hook signature mismatch");
    return parseJsonString(data);
}

alias HandlePR = void delegate(string action, string repoSlug, string pullRequestURL, uint pullRequestNumber, string commitsURL, string commentsURL);

struct GithubHook
{
    HandlePR run;

    void hook(HTTPServerRequest req, HTTPServerResponse res)
    {
        import vibe.stream.operations : readAllUTF8;
        import vibe.core.core : runTask;

        auto json = verifyRequest(req.headers["X-Hub-Signature"], req.bodyReader.readAllUTF8);
        if (req.headers["X-Github-Event"] == "ping")
            return res.writeBody("pong");
        if (req.headers["X-GitHub-Event"] != "pull_request")
            return res.writeVoidBody();

        auto action = json["action"].get!string;
        logDebug("#%s %s", json["number"], action);
        switch (action)
        {
        case "closed":
            if (json["pull_request"]["merged"].get!bool)
                action = "merged";
            goto case;
        case "opened", "reopened", "synchronize":
            auto repoSlug = json["pull_request"]["base"]["repo"]["full_name"].get!string;
            auto pullRequestURL = json["pull_request"]["html_url"].get!string;
            auto pullRequestNumber = json["pull_request"]["number"].get!uint;
            auto commitsURL = json["pull_request"]["commits_url"].get!string;
            auto commentsURL = json["pull_request"]["comments_url"].get!string;
            runTask(run, action, repoSlug, pullRequestURL, pullRequestNumber, commitsURL, commentsURL);
            return res.writeBody("handled");
        default:
            return res.writeBody("ignored");
        }
    }
}

//==============================================================================
// Github comments
//==============================================================================

string formatComment(R1, R2)(R1 refs, R2 descs)
{
    import std.algorithm.iteration : map;
    import std.array : appender;
    import std.format : formattedWrite;
    import std.range : zip;

    auto combined = zip(refs.map!(r => r.id), refs.map!(r => r.fixed), descs.map!(d => d.desc));
    auto app = appender!string();
    app.put("Fix | Bugzilla | Description\n");
    app.put("--- | --- | ---\n");
    foreach (num, closed, desc; combined)
    {
        app.formattedWrite(
            "%1$s | [%2$s](https://issues.dlang.org/show_bug.cgi?id=%2$s) | %3$s\n",
            closed ? "✓" : "✗", num, desc);
    }
    return app.data;
}

unittest
{
    auto refs = [IssueRef(42, true), IssueRef(43, true)];
    auto descs= [Issue(42, "DlangBot is alive"), Issue(43, "DlangBot is dead")];
    auto res =
`Fix | Bugzilla | Description
--- | --- | ---
✓ | [42](https://issues.dlang.org/show_bug.cgi?id=42) | DlangBot is alive
✓ | [43](https://issues.dlang.org/show_bug.cgi?id=43) | DlangBot is dead
`;

    assert(formatComment(refs, descs) == res);
}

Comment getBotComment(string commentsURL)
{
    import std.algorithm.searching : find;
    auto res = requestHTTP(commentsURL, (scope req) { req.headers["Authorization"] = githubAuth; })
        .readJson[]
        .find!(c => c["user"]["login"] == "dlang-bot");
    if (res.length)
        return deserializeJson!Comment(res[0]);
    return Comment();
}

void ghSendRequest(T...)(HTTPMethod method, string url, T arg)
    if (T.length <= 1)
{
    import vibe.stream.operations : readAllUTF8;
    requestHTTP(url, (scope req) {
        req.headers["Authorization"] = githubAuth;
        req.method = method;
        static if (T.length)
            req.writeJsonBody(arg);
    }, (scope res) {
        if (res.statusCode / 100 == 2)
            logInfo("%s %s, %s\n", method, url, res.bodyReader.empty ?
                    res.statusPhrase : res.readJson["html_url"].get!string);
        else
            logWarn("%s %s failed;  %s %s.\n%s", method, url,
                res.statusPhrase, res.statusCode, res.bodyReader.readAllUTF8);
    });
}

void updateGithubComment(string action, IssueRef[] refs, Issue[] descs, string commentsURL)
{
    import std.algorithm.iteration : map;
    import std.algorithm.comparison : equal;
    import std.range : empty;

    auto comment = getBotComment(commentsURL);
    logDebug("%s", refs);
    if (refs.empty)
    {
        if (comment.url.length) // delete any existing comment
            ghSendRequest(HTTPMethod.DELETE, comment.url);
        return;
    }
    logDebug("%s", descs);
    assert(refs.map!(r => r.id).equal(descs.map!(d => d.id)));

    auto msg = formatComment(refs, descs);
    logDebug("%s", msg);

    if (msg != comment.body_)
    {
        if (comment.url.length)
            ghSendRequest(HTTPMethod.PATCH, comment.url, ["body" : msg]);
        else if (action != "closed" && action != "merged")
            ghSendRequest(HTTPMethod.POST, commentsURL, ["body" : msg]);
    }
}
