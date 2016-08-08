module dlangbot.trello;

import dlangbot.comment;
import dlangbot.issue;
import std.range : front, empty;
import vibe.core.log;
import vibe.data.json;
import vibe.http.client : requestHTTP;
import vibe.http.common : HTTPMethod;
import vibe.http.server : HTTPServerRequest, HTTPServerResponse;
string trelloSecret, trelloAuth;

//==============================================================================
// Trello cards
//==============================================================================

void trelloSendRequest(T...)(HTTPMethod method, string url, T arg)
    if (T.length <= 1)
{
    import std.array : replace;
    import vibe.stream.operations : readAllUTF8;

    requestHTTP(url, (scope req) {
        req.method = method;
        static if (T.length)
            req.writeJsonBody(arg);
    }, (scope res) {
        if (res.statusCode / 100 == 2)
            logInfo("%s %s: %s\n", method, url.replace(trelloAuth, "key=[hidden]&token=[hidden]")
                    , res.statusPhrase);
        else
            logWarn("%s %s: %s %s.\n%s", method, url.replace(trelloAuth, "key=[hidden]&token=[hidden]"),
                res.statusPhrase, res.statusCode, res.bodyReader.readAllUTF8);
    });
}

struct TrelloCard { string id; int issueID; }

string trelloAPI(Args...)(string fmt, Args args)
{
    import std.algorithm.searching : canFind;
    import std.format : format;
    import std.uri : encode;
    return encode("https://api.trello.com"~fmt.format(args)~(fmt.canFind("?") ? "&" : "?")~trelloAuth);
}

string formatTrelloComment(string existingComment, Issue[] issues)
{
    import std.algorithm.iteration : filter, each;
    import std.algorithm.searching : canFind;
    import std.array : appender;
    import std.format : formattedWrite;
    import std.stdio : KeepTerminator;
    import std.string : lineSplitter;

    auto app = appender!string();
    foreach (issue; issues)
        app.formattedWrite("- [Issue %1$d - %2$s](https://issues.dlang.org/show_bug.cgi?id=%1$d)\n", issue.id, issue.desc);

    existingComment
        .lineSplitter!(KeepTerminator.yes)
        .filter!(line => !line.canFind("issues.dlang.org"))
        .each!(ln => app.put(ln));
    return app.data;
}

string formatTrelloComment(string existingComment, string pullRequestURL)
{
    import std.algorithm.iteration : each;
    import std.algorithm.searching : canFind;
    import std.array : appender;
    import std.format : formattedWrite;
    import std.stdio : KeepTerminator;
    import std.string : lineSplitter;

    auto app = appender!string();

    auto lines = existingComment
        .lineSplitter!(KeepTerminator.yes);
    lines.each!(ln => app.put(ln));
    if (!lines.canFind!(line => line.canFind(pullRequestURL)))
        app.formattedWrite("- %s\n", pullRequestURL);
    return app.data;
}

auto findTrelloCards(int issueID)
{
    import std.algorithm.iteration : map;
    return trelloAPI("/1/search?query=name:'Issue %d'", issueID)
        .requestHTTP
        .readJson["cards"][]
        .map!(c => TrelloCard(c["id"].get!string, issueID));
}

Comment getTrelloBotComment(string cardID)
{
    import std.algorithm.searching : find;
    auto res = trelloAPI("/1/cards/%s/actions?filter=commentCard", cardID)
        .requestHTTP
        .readJson[]
        .find!(c => c["memberCreator"]["username"] == "dlangbot");
    if (res.length)
        return Comment(
            trelloAPI("/1/cards/%s/actions/%s/comments", cardID, res[0]["id"].get!string),
            res[0]["data"]["text"].get!string);
    return Comment();
}

void moveCardToList(string cardID, string listName)
{
    import std.algorithm.searching : find;
    import std.string : startsWith;

    logInfo("moveCardToDone %s", cardID);
    auto card = trelloAPI("/1/cards/%s", cardID)
        .requestHTTP
        .readJson;
    auto listID = trelloAPI("/1/board/%s/lists", card["idBoard"].get!string)
        .requestHTTP
        .readJson[]
        .find!(c => c["name"].get!string.startsWith(listName))
        .front["id"].get!string;
    if (card["idList"] == listID)
        return;
    trelloSendRequest(HTTPMethod.PUT, trelloAPI("/1/cards/%s/idList?value=%s", cardID, listID));
    trelloSendRequest(HTTPMethod.PUT, trelloAPI("/1/cards/%s/pos?value=bottom", cardID));
}

void updateTrelloCard(string action, string pullRequestURL, IssueRef[] refs, Issue[] descs)
{
    import std.array : array;
    import std.algorithm.iteration;
    import std.algorithm.searching : all, canFind, find;
    foreach (grp; descs.map!(d => findTrelloCards(d.id)).joiner.array.chunkBy!((a, b) => a.id == b.id))
    {
        auto cardID = grp.front.id;
        auto comment = getTrelloBotComment(cardID);
        auto issues = descs.filter!(d => grp.canFind!((tc, issueID) => tc.issueID == issueID)(d.id));
        logDebug("%s %s", cardID, issues);
        if (issues.empty)
        {
            if (comment.url.length)
                trelloSendRequest(HTTPMethod.DELETE, comment.url);
            return;
        }

        auto msg = formatTrelloComment(comment.body_, pullRequestURL);
        logDebug("%s", msg);

        if (msg != comment.body_)
        {
            if (comment.url.length)
                trelloSendRequest(HTTPMethod.PUT, comment.url, ["text": msg]);
            else if (action != "closed")
                trelloSendRequest(HTTPMethod.POST, trelloAPI("/1/cards/%s/actions/comments", cardID), ["text": msg]);
        }

        if ((action == "opened" || action == "merged") &&
            grp.all!(tc => refs.find!(r => r.id == tc.issueID).front.fixed))
            moveCardToList(cardID, action == "opened" ? "Testing" : "Done");
    }
}

void updateTrelloCard(string cardID, IssueRef[] refs, Issue[] descs)
{
    auto comment = getTrelloBotComment(cardID);
    auto issues = descs;
    logDebug("%s %s", cardID, issues);
    if (issues.empty)
    {
        if (comment.url.length)
            trelloSendRequest(HTTPMethod.DELETE, comment.url);
        return;
    }

    auto msg = formatTrelloComment(comment.body_, issues);
    logDebug("%s", msg);

    if (msg != comment.body_)
    {
        if (comment.url.length)
            trelloSendRequest(HTTPMethod.PUT, comment.url, ["text": msg]);
        else
            trelloSendRequest(HTTPMethod.POST, trelloAPI("/1/cards/%s/actions/comments", cardID), ["text": msg]);
    }
}

//==============================================================================
// Trello hook
//==============================================================================

Json verifyTrelloRequest(string signature, string body_, string url)
{
    import std.algorithm.iteration : map;
    import std.digest.digest, std.digest.hmac, std.digest.sha;
    import std.exception : enforce;
    import std.range : chain;
    import std.string : representation;

    static ubyte[28] base64Digest(Range)(Range range)
    {
        import std.base64;

        auto hmac = HMAC!SHA1(trelloSecret.representation);
        foreach (c; range)
            hmac.put(c);
        ubyte[28] buf = void;
        Base64.encode(hmac.finish, buf[]);
        return buf;
    }

    import std.utf : byUTF;
    enforce(
        base64Digest(base64Digest(body_.byUTF!dchar.map!(c => cast(immutable ubyte) c).chain(url.representation))) ==
        base64Digest(signature.representation), "Hook signature mismatch");
    return parseJsonString(body_);
}

struct TrelloHook
{
    void delegate(string id, string name) run;

    void hook(HTTPServerRequest req, HTTPServerResponse res)
    {
        import vibe.stream.operations : readAllUTF8;
        auto url = "https://dlang-bot.herokuapp.com/trello_hook";
        auto json = verifyTrelloRequest(req.headers["X-Trello-Webhook"], req.bodyReader.readAllUTF8, url);
        logDebug("trelloHook %s", json);
        auto action = json["action"]["type"].get!string;
        switch (action)
        {
        case "createCard", "updateCard":
            string id = json["action"]["data"]["card"]["id"].get!string;
            string name = json["action"]["data"]["card"]["name"].get!string;
            run(id, name);
            break;
        default:
            return res.writeBody("ignored");
        }
        res.writeVoidBody;
    }
}
