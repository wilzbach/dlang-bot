module utils;

import vibe.d, std.algorithm, std.process, std.range, std.regex, std.stdio;
import std.functional, std.string;

// forward commonly needed imports
public import dlangbot.app;
public import vibe.http.common : HTTPMethod, HTTPStatus;
public import vibe.http.client : HTTPClientRequest;
public import vibe.http.server : HTTPServerRequest, HTTPServerResponse;
public import std.functional : toDelegate;
public import vibe.data.json : deserializeJson, Json;
public import std.datetime : SysTime;
public import std.algorithm;

// existing dlang bot comment -> update comment

string testServerURL;
string ghTestHookURL;
string trelloTestHookURL;

string payloadDir = "./data/payloads";
string hookDir = "./data/hooks";

/// Tries to find a free port
ushort getFreePort()
{
    import std.conv : to;
    import std.socket : AddressFamily, InternetAddress, Socket, SocketType;
    auto s = new Socket(AddressFamily.INET, SocketType.STREAM);
    scope(exit) s.close;
    s.bind(new InternetAddress(0));
    return s.localAddress.toPortString.to!ushort;
}

version(unittest)
shared static this()
{
    // overwrite environment configs
    githubAuth = "GH_DUMMY_AUTH_TOKEN";
    hookSecret = "GH_DUMMY_HOOK_SECRET";
    trelloAuth = "key=01234&token=abcde";

    // start our hook server
    auto settings = new HTTPServerSettings;
    settings.port = getFreePort;
    startServer(settings);
    startFakeAPIServer();
    startFakeGitServer();

    testServerURL = "http://" ~ settings.bindAddresses[0] ~ ":"
                             ~ settings.port.to!string;
    ghTestHookURL = testServerURL ~ "/github_hook";
    trelloTestHookURL = testServerURL ~ "/trello_hook";

    import vibe.core.log;
    setLogLevel(LogLevel.info);

    runAsync = false;
}

void startFakeAPIServer()
{
    // start a fake API server
    auto fakeSettings = new HTTPServerSettings;
    fakeSettings.port = getFreePort;
    fakeSettings.bindAddresses = ["0.0.0.0"];
    auto router = new URLRouter;
    router.any("*", &payloadServer);

    listenHTTP(fakeSettings, router);

    auto fakeAPIServerURL = "http://" ~ fakeSettings.bindAddresses[0] ~ ":"
                                      ~ fakeSettings.port.to!string;

    githubAPIURL = fakeAPIServerURL ~ "/github";
    trelloAPIURL = fakeAPIServerURL ~ "/trello";
    bugzillaURL = fakeAPIServerURL ~ "/bugzilla";
}

/*
  pkt-line     =  data-pkt / flush-pkt

  data-pkt     =  pkt-len pkt-payload
  pkt-len      =  4*(HEXDIG)
  pkt-payload  =  (pkt-len - 4)*(OCTET)

  flush-pkt    = "0000"

Source: https://github.com/git/git/blob/master/Documentation/technical/protocol-common.txt
*/
auto pktLen(string payload)
{
    if (payload is null)
        return "0000";
    // pkt-len is encoded as four hex digits
    return format("%.4x%s", payload.length + 4, payload);
}

unittest
{
    assert(null.pktLen == "0000");
    assert("".pktLen == "0004");
    assert("a".pktLen == "0005a");
    assert("a\n".pktLen == "0006a\n");
    assert("unpack ok\n".pktLen == "000eunpack ok\n");
    assert("ok refs/heads/debug\n".pktLen == "0018ok refs/heads/debug\n");
    assert("# service=git-receive-pack\n".pktLen == "001f# service=git-receive-pack\n");
    assert("6e79d22fdfda446601d969ce77e406b9a5506de8 refs/heads/Issue_8574\n".pktLen
            == "00436e79d22fdfda446601d969ce77e406b9a5506de8 refs/heads/Issue_8574\n");
}

string parsePktLen()(auto ref string payload)
{
    import std.format;
    int len;
    auto s = payload[0 .. 4];
    s.formattedRead("%x", &len);
    if (len == 0)
    {
        payload.popFrontN(4);
        return null;
    }
    s = payload[4 .. len];
    payload.popFrontN(len);
    return s;
}

unittest
{
    assert("0004".parsePktLen == "");
    assert("0005a".parsePktLen == "a");
    assert("0018ok refs/heads/debug\n".parsePktLen == "ok refs/heads/debug\n");

    string a = "0005ab";
    assert(a.parsePktLen == "a");
    assert(a == "b");

    string flush = "0000a";
    assert(flush.parsePktLen is null);
    assert(flush  == "a");
}

auto readPktlines(ubyte[] payload)
{
    string[] els;
    auto p = cast(string) payload;
    while (payload.length > 0)
    {
        auto el = p.parsePktLen;
        // after the flush, only PACK with binary data is sent
        if (el is null)
            break;
        els ~= el;
    }
    return els;
}

unittest
{
    ubyte[] req = [48, 48, 51, 53, 115, 104, 97, 108, 108, 111, 119, 32, 54, 101, 55, 57, 100, 50, 50, 102, 100, 102, 100, 97, 52, 52, 54, 54, 48, 49, 100, 57, 54, 57, 99, 101, 55, 55, 101, 52, 48, 54, 98, 57, 97, 53, 53, 48, 54, 100, 101, 56, 10, 48, 48, 56, 98, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 32, 54, 101, 55, 57, 100, 50, 50, 102, 100, 102, 100, 97, 52, 52, 54, 54, 48, 49, 100, 57, 54, 57, 99, 101, 55, 55, 101, 52, 48, 54, 98, 57, 97, 53, 53, 48, 54, 100, 101, 56, 32, 114, 101, 102, 115, 47, 104, 101, 97, 100, 115, 47, 73, 115, 115, 117, 101, 95, 57, 48, 48, 48, 0, 32, 114, 101, 112, 111, 114, 116, 45, 115, 116, 97, 116, 117, 115, 32, 97, 103, 101, 110, 116, 61, 103, 105, 116, 47, 50, 46, 49, 51, 46, 49, 48, 48, 48, 48, 80, 65, 67, 75, 0, 0, 0, 2, 0, 0, 0, 0, 2, 157, 8, 130, 59, 216, 168, 234, 181, 16, 173, 106, 199, 92, 130, 60, 253, 62, 211, 30];
    assert(req.readPktlines == ["shallow 6e79d22fdfda446601d969ce77e406b9a5506de8\n", "0000000000000000000000000000000000000000 6e79d22fdfda446601d969ce77e406b9a5506de8 refs/heads/Issue_9000\0 report-status agent=git/2.13.1"]);
}

// ignores push-cert commands
auto parseGitClientRequest(string[] lines)
{
    static immutable zeroString = "0000000000000000000000000000000000000000";
    GitClientRequest req;
    while (!lines.empty && lines.front.startsWith("shallow"))
    {
        auto line = lines.front;
        line.skipOver("shallow ");
        req.shallowRefs ~= line.stripRight;
        lines.popFront;
    }
    if (lines.empty)
        return req;
    enforce(!lines.front.startsWith("push-cert"), "push-cert is not supported");
    foreach (rawLine; lines)
    {
        GitClientRequest.Command command;
        command.command = GitClientRequest.Command.Action.update;
        auto line = rawLine.until("\0").to!string.splitter(" ");
        command.oldId = line.front;
        line.popFront;
        command.newId = line.front;
        line.popFront;
        command.ref_ = line.front;
        if (command.oldId.equal(zeroString))
            command.command = GitClientRequest.Command.Action.create;
        else if (command.newId.equal(zeroString))
            command.command = GitClientRequest.Command.Action.delete_;

        req.commands ~= command;
    }
    return req;
}

unittest
{
    auto req = ["shallow 6e79d22fdfda446601d969ce77e406b9a5506de8\n", "0000000000000000000000000000000000000000 6e79d22fdfda446601d969ce77e406b9a5506de8 refs/heads/Issue_9000\0 report-status agent=git/2.13.1"].parseGitClientRequest;
    assert(req == GitClientRequest(["6e79d22fdfda446601d969ce77e406b9a5506de8"],
                [GitClientRequest.Command(
                    GitClientRequest.Command.Action.create,
                    "0000000000000000000000000000000000000000",
                    "6e79d22fdfda446601d969ce77e406b9a5506de8",
                    "refs/heads/Issue_9000"
                    )
                ]));
}

struct GitClientRequest
{
    string[] shallowRefs;
    struct Command {
        enum Action { create, delete_, update}
        Action command;
        string oldId, newId, ref_;
    }
    Command[] commands;
}

struct GitInfoRef
{
    string sha; // 40 chars
    string ref_;
    string toString()
    {
        return sha ~ " " ~ ref_;
    }
}

__gshared GitInfoRef[] function(string user, string repo) gitInfoRefs;

struct GitReportRef
{
    enum Status : string {
        ok = "ok",
        notOk = "ng"
    }
    Status status;
    string ref_;
    string msg; // only for notOk e.g. "non-fast-forward"
    string toString()
    {
        string s = status ~ " " ~ ref_;
        if (status == Status.notOk)
            s ~= " " ~ msg;
        return s;
    }
}
alias ClientReq = GitClientRequest;

__gshared GitReportRef[] function(ClientReq clientReq) gitReportRefs;

void startFakeGitServer()
{
    import dlangbot.git : gitURL;
    // start a fake API server
    auto fakeSettings = new HTTPServerSettings;
    fakeSettings.port = 9006;
    //fakeSettings.port = getFreePort;
    fakeSettings.bindAddresses = ["0.0.0.0"];
    auto router = new URLRouter;
    import std.conv;

    // the client first requests a list of all HEAD & tag references on the server
    // https://github.com/git/git/blob/master/Documentation/technical/http-protocol.txt
    // if a ref can be found here, the won't re-upload
    router.get("/:user/:repo/info/refs", (req, res){
        assert(req.query["service"] == "git-receive-pack");
        res.contentType = "application/x-git-receive-pack-advertisement";
        // TODO: limit capabilities?
        const capabilities = "\0report-status delete-refs atomic ofs-delta agent=git/2.13.1";

        // different hash requires force-push
        auto lines = gitInfoRefs(req.params["user"], req.params["repo"]).map!(to!string);

        // pktl
        auto resp = text("# service=git-receive-pack".pktLen,
            // flush package
            "0000",
            only(lines.front ~ capabilities)
                // first line must list capabilities after NUL
                .chain(lines.dropOne)
                .map!(e => (e ~ "\n").pktLen)
                .joiner,
            // flush package
            "0000"
        );
        res.writeBody(resp);
    });
    // https://github.com/git/git/blob/master/Documentation/technical/pack-protocol.txt
    router.post("/:user/:repo/git-receive-pack", (req, res){
        assert(req.contentType == "application/x-git-receive-pack-request");
        res.contentType = "application/x-git-receive-pack-result";
        auto clientReq = req.bodyReader
            .readAll
            .readPktlines
            .parseGitClientRequest;

// current new name capabilities
// new branch with full history
//["0000000000000000000000000000000000000000 6e79d22fdfda446601d969ce77e406b9a5506de8 refs/heads/Issue_8579\0 report-status agent=git/2.13.1"]
// force-push with full history
//["6e79d22fdfda446601d969ce77e406b9a5506de9 6e79d22fdfda446601d969ce77e406b9a5506de8 refs/heads/Issue_8573\0 report-status agent=git/2.13.1"]
// new branch with shallow history
//["shallow 6e79d22fdfda446601d969ce77e406b9a5506de8\n", "0000000000000000000000000000000000000000 49d16bdc575f4f007e1bf34c3482b63e6b0fd313 refs/heads/Issue_9001\0 report-status agent=git/2.13.1"]
// force-push with shallow history
//["shallow 6e79d22fdfda446601d969ce77e406b9a5506de8\n", "6e79d22fdfda446601d969ce77e406b9a5506de9 49d16bdc575f4f007e1bf34c3482b63e6b0fd313 refs/heads/Issue_8573\0 report-status agent=git/2.13.1"

        auto resp = text(
            // flush package (skips sideband information)
            chain(
                // initial confirmation
                "unpack ok".only,
                // report for individual branches
                // Each line is either 'ok [refname]' if the update was successful,
                // or 'ng [refname] [error]' if the update was not.
                // no response -> everything up to date
                //"ok refs/heads/Issue_8573",
                //"ng refs/heads/Issue_8573 non-fast-forward",
                gitReportRefs(clientReq).map!(to!string),
            ).map!(e => (e ~ "\n").pktLen).joiner,
            "0000"
        );
        res.writeBody(resp);
    });
    router.any("*", (req, res){
        writeln("UNEXPECTED GIT ACCESS: ", req.path, " ", req.method);
        res.headers["Content-Type"] = "application/xml";
        res.writeBody(".");
    });
    listenHTTP(fakeSettings, router);
    gitURL = "http://" ~ fakeSettings.bindAddresses[0] ~ ":"
                            ~ fakeSettings.port.to!string;
}

// serves saved GitHub API payloads
auto payloadServer(scope HTTPServerRequest req, scope HTTPServerResponse res)
{
    import std.path, std.file;
    APIExpectation expectation = void;

    // simple observer that checks whether a request is expected
    auto idx = apiExpectations.map!(x => x.url).countUntil(req.requestURL);
    if (idx >= 0)
    {
        expectation = apiExpectations[idx];
        if (apiExpectations.length > 1)
            apiExpectations = apiExpectations[0 .. idx] ~ apiExpectations[idx + 1 .. $];
        else
            apiExpectations.length = 0;
    }
    else
    {
        scope(failure) {
            writeln("Remaining expected URLs:", apiExpectations.map!(x => x.url));
        }
        assert(0, "Request for unexpected URL received: " ~ req.requestURL);
    }

    res.statusCode = expectation.respStatusCode;
    // set failure status code exception to suppress false errors
    import dlangbot.utils : _expectedStatusCode;
    if (expectation.respStatusCode / 100 != 2)
        _expectedStatusCode = expectation.respStatusCode;

    string filePath = buildPath(payloadDir, req.requestURL[1 .. $].replace("/", "_"));

    if (expectation.reqHandler !is null)
    {
        scope(failure) {
            writefln("Method: %s", req.method);
            writefln("Json: %s", req.json);
        }
        expectation.reqHandler(req, res);
        if (res.headerWritten)
            return;
        if (!filePath.exists)
            return res.writeVoidBody;
    }

    if (!filePath.exists)
    {
        assert(0, "Please create payload: " ~ filePath);
    }
    else
    {
        logInfo("reading payload: %s", filePath);
        auto payload = filePath.readText;
        if (req.requestURL.startsWith("/github", "/trello"))
        {
            auto payloadJson = payload.parseJsonString;
            replaceAPIReferences("https://api.github.com", githubAPIURL, payloadJson);
            replaceAPIReferences("https://api.trello.com", trelloAPIURL, payloadJson);

            if (expectation.jsonHandler !is null)
                expectation.jsonHandler(payloadJson);

            return res.writeJsonBody(payloadJson);
        }
        else
        {
            return res.writeBody(payload);
        }
    }
}

void replaceAPIReferences(string official, string local, ref Json json)
{
    void recursiveReplace(ref Json j)
    {
        switch (j.type)
        {
        case Json.Type.array:
        case Json.Type.object:
            j.each!recursiveReplace;
            break;
        case Json.Type.string:
            string v = j.get!string;
            if (v.countUntil(official) >= 0)
                j = v.replace(official, githubAPIURL);
            break;
        default:
            break;
        }
    }
    recursiveReplace(json);
}

struct APIExpectation
{
    /// the called server url
    string url;

    /// implement a custom request handler
    private void delegate(scope HTTPServerRequest req, scope HTTPServerResponse res) reqHandler;

    /// modify the json of the payload before being served
    private void delegate(ref Json j) jsonHandler;

    /// respond with the given status
    HTTPStatus respStatusCode = HTTPStatus.ok;

    this(string url)
    {
        this.url = url;
    }
}

__gshared APIExpectation[] apiExpectations;

void setAPIExpectations(Args...)(Args args)
{
    import std.functional : toDelegate;
    import std.traits :  Parameters;
    synchronized {
    apiExpectations.length = 0;
    foreach (i, arg; args)
    {
        static if (is(Args[i] : string))
        {
            apiExpectations ~= APIExpectation(arg);
        }
        else static if (is(Args[i] : HTTPStatus))
        {
            apiExpectations[$ - 1].respStatusCode = arg;
        }
        else
        {
            alias params = Parameters!arg;
            static if (is(params[0] : HTTPServerRequest))
            {
                apiExpectations[$ - 1].reqHandler = arg.toDelegate;
            }
            else static if (is(params[0] : Json))
            {
                apiExpectations[$ - 1].jsonHandler = arg.toDelegate;
            }
            else
            {
                static assert(0, "Unknown handler type");
            }
            assert(apiExpectations[$ - 1].jsonHandler is null ||
                   apiExpectations[$ - 1].reqHandler is null, "Either provide a reqHandler or a jsonHandler");
        }
    }
    }
}

void checkAPIExpectations()
{
    scope(failure) {
        writefln("Didn't request: %s", apiExpectations.map!(x => x.url));
    }
    assert(apiExpectations.length == 0);
}

void postGitHubHook(string payload, string eventType = "pull_request",
    void delegate(ref Json j, scope HTTPClientRequest req) postprocess = null,
    int line = __LINE__, string file = __FILE__)
{
    import std.file : readText;
    import std.path : buildPath;
    import dlangbot.github : getSignature;

    logInfo("Starting test in %s:%d with payload: %s", file, line, payload);

    payload = hookDir.buildPath("github", payload);

    auto req = requestHTTP(ghTestHookURL, (scope req) {
        req.method = HTTPMethod.POST;

        auto payload = payload.readText.parseJsonString;

        // localize accessed URLs
        replaceAPIReferences("https://api.github.com", githubAPIURL, payload);

        req.headers["X-GitHub-Event"] = eventType;

        if (postprocess !is null)
            postprocess(payload, req);

        auto respStr = payload.toString;
        req.headers["X-Hub-Signature"] = getSignature(respStr);
        req.writeBody(cast(ubyte[]) respStr);
    });
    scope(failure) {
        if (req.statusCode != 200)
            writeln(req.bodyReader.readAllUTF8);
    }
    assert(req.statusCode == 200);
    assert(req.bodyReader.readAllUTF8 == "handled");
    checkAPIExpectations;
}

void postTrelloHook(string payload,
    void delegate(ref Json j, scope HTTPClientRequest req) postprocess = null,
    int line = __LINE__, string file = __FILE__)
{
    import std.file : readText;
    import std.path : buildPath;
    import dlangbot.trello : getSignature;

    payload = hookDir.buildPath("trello", payload);

    logInfo("Starting test in %s:%d with payload: %s", file, line, payload);

    auto req = requestHTTP(trelloTestHookURL, (scope req) {
        req.method = HTTPMethod.POST;

        auto payload = payload.readText.parseJsonString;

        // localize accessed URLs
        replaceAPIReferences("https://api.trello.com", trelloAPIURL, payload);

        if (postprocess !is null)
            postprocess(payload, req);

        auto respStr = payload.toString;
        req.headers["X-Trello-Webhook"] = getSignature(respStr, trelloHookURL);
        req.writeBody(cast(ubyte[]) respStr);
    });
    scope(failure) {
        if (req.statusCode != 200)
            writeln(req.bodyReader.readAllUTF8);
    }
    assert(req.statusCode == 200);
    assert(req.bodyReader.readAllUTF8 == "handled");
    checkAPIExpectations;
}

void openUrl(string url, string expectedResponse,
    int line = __LINE__, string file = __FILE__)
{
    import std.file : readText;
    import std.path : buildPath;

    logInfo("Starting test in %s:%d with url: %s", file, line, url);

    auto req = requestHTTP(testServerURL ~ url, (scope req) {
        req.method = HTTPMethod.GET;
    });
    scope(failure) {
        if (req.statusCode != 200)
            writeln(req.bodyReader.readAllUTF8);
    }
    assert(req.statusCode == 200);
    checkAPIExpectations;
    assert(req.bodyReader.readAllUTF8 == expectedResponse);
}

void testCronDaily(string[] repositories, int line = __LINE__, string file = __FILE__)
{
    import dlangbot.app : cronDaily;
    import dlangbot.cron : CronConfig;

    logInfo("Starting cron test in %s:%d", file, line);

    CronConfig config = {
        simulate: false,
        waitAfterMergeNullState: 1.msecs,
    };
    cronDaily(repositories, config);
    checkAPIExpectations;
}
