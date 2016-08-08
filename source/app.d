import std.process : environment;
import vibe.http.server : HTTPServerSettings;

HTTPServerSettings settings;

//version(VibeDefaultMain)
shared static this()
{
    import dlangbot.github : GithubHook;
    import dlangbot.trello : TrelloHook;

    import vibe.core.args : readOption;
    import vibe.core.core : vibeVersionString;
    import vibe.http.client : HTTPClient;
    import vibe.http.common : HTTPMethod;
    import vibe.http.fileserver : serveStaticFiles;
    import vibe.http.router : URLRouter;
    import vibe.http.server : HTTPServerOption, render, listenHTTP;

    settings = new HTTPServerSettings;
    settings.port = 8080;
    settings.bindAddresses = ["0.0.0.0"];
    settings.options = HTTPServerOption.defaults & ~HTTPServerOption.parseJsonBody;
    readOption("port|p", &settings.port, "Sets the port used for serving.");

    import std.functional : toDelegate;
    auto gh = GithubHook(toDelegate(&handlePR));
    auto tr = TrelloHook(toDelegate(&handleTrello));

    auto router = new URLRouter;
    router
        .get("/", (req, res) => res.render!"index.dt")
        .get("*", serveStaticFiles("public"))
        .post("/github_hook", &gh.hook)
        .match(HTTPMethod.HEAD, "/trello_hook", (req, res) => res.writeVoidBody)
        .post("/trello_hook", &tr.hook)
        ;
    listenHTTP(settings, router);

    import dlangbot.github : githubAuth, hookSecret;
    import dlangbot.trello : trelloAuth, trelloSecret;
    import dlangbot.travis : travisAuth;

    version(unittest)
    {
        environment["GH_TOKEN"] = "foo";
        environment["GH_HOOK_SECRET"] = "foo";
        environment["TRELLO_SECRET"] = "foo";
        environment["TRELLO_KEY"] = "foo";
        environment["TRELLO_TOKEN"] = "foo";
        environment["TRAVIS_TOKEN"] = "foo";
    }

    githubAuth = "token "~environment["GH_TOKEN"];
    trelloSecret = environment["TRELLO_SECRET"];
    trelloAuth = "key="~environment["TRELLO_KEY"]~"&token="~environment["TRELLO_TOKEN"];
    hookSecret = environment["GH_HOOK_SECRET"];
    travisAuth = "token " ~ environment["TRAVIS_TOKEN"];

    // workaround for stupid openssl.conf on Heroku
    HTTPClient.setTLSSetupCallback((ctx) {
        ctx.useTrustedCertificateFile("/etc/ssl/certs/ca-certificates.crt");
    });
    HTTPClient.setUserAgentString("dlang-bot vibe.d/"~vibeVersionString);

version(unittest)
{
    import std.conv : to;
    import std.datetime : seconds;
    import vibe.core.core : setTimer;
    //import vibe.core.driver : exitEventLoop;
    import vibe.http.client : requestHTTP;
    import vibe.http.common : HTTPMethod;
    import vibe.stream.operations : readAllUTF8;

    auto baseURL = "http://" ~ settings.bindAddresses[0] ~ ":"
                             ~ settings.port.to!string;

    import vibe.core.log;
    setLogLevel(LogLevel.debugV);

    import std.file : readText;
    auto testFile = "tests/payload_pr_synchronized.json".readText;
    auto req = requestHTTP(baseURL ~ "/github_hook", (scope req) {
            import dlangbot.github : getSignature;
            req.method = HTTPMethod.POST;
            req.headers["X-Hub-Signature"] = getSignature(testFile);
            req.headers["X-GitHub-Event"] = "pull_request";
            req.writeBody(cast(ubyte[]) testFile);
    });
    assert(req.statusCode == 200);
    assert(req.bodyReader.readAllUTF8() == "handled");
}
}

//==============================================================================

void handlePR(string action, string repoSlug, string pullRequestURL, uint pullRequestNumber, string commitsURL, string commentsURL)
{
    import dlangbot.bugzilla : getIssueRefs, getDescriptions;
    import dlangbot.github : updateGithubComment;
    import dlangbot.trello : updateTrelloCard;
    import dlangbot.travis : dedupTravisBuilds;
    import std.datetime : seconds;
    import vibe.core.core : setTimer;

    auto refs = getIssueRefs(commitsURL);
    auto descs = getDescriptions(refs);

    updateGithubComment(action, refs, descs, commentsURL);
    updateTrelloCard(action, pullRequestURL, refs, descs);
    // wait until builds for the current push are created
    setTimer(30.seconds, { dedupTravisBuilds(action, repoSlug, pullRequestNumber); });
}

void handleTrello(string id, string name)
{
    import dlangbot.bugzilla : getDescriptions, matchIssueRefs;
    import dlangbot.trello : updateTrelloCard;
    import std.array : array;

    auto refs = matchIssueRefs(name).array;
    auto descs = getDescriptions(refs);
    updateTrelloCard(id, refs, descs);
}
