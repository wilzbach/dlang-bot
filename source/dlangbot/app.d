module dlangbot.app;

import dlangbot.bugzilla;
import dlangbot.cron;
import dlangbot.github;
import dlangbot.trello;
import dlangbot.utils;

public import dlangbot.bugzilla : bugzillaURL;
public import dlangbot.github_api   : githubAPIURL, githubAuth, hookSecret;
public import dlangbot.trello   : trelloAPIURL, trelloAuth, trelloSecret;

import std.datetime : Clock, days, Duration, minutes, seconds, SysTime;

import vibe.core.args;
import vibe.core.core;
import vibe.core.log;
import vibe.data.json;
import vibe.http.client : HTTPClient;
import vibe.http.common : enforceBadRequest, enforceHTTP, HTTPMethod, HTTPStatus;
import vibe.http.router : URLRouter;
import vibe.http.server : HTTPServerRequest, HTTPServerResponse, HTTPServerSettings;
import vibe.stream.operations : readAllUTF8;

bool runAsync = true;
bool runTrello = true;

Duration timeBetweenFullPRChecks = 1.minutes; // this should never be larger 30 mins on heroku
Throttler!(typeof(&searchForAutoMergePrs)) prThrottler;

enum trelloHookURL = "https://dlang-bot.herokuapp.com/trello_hook";

void startServer(HTTPServerSettings settings)
{
    import vibe.core.core : vibeVersionString;
    import vibe.http.fileserver : serveStaticFiles;
    import vibe.http.server : HTTPServerOption, listenHTTP, render;

    settings.bindAddresses = ["0.0.0.0"];

    auto router = new URLRouter;
    router
        .get("/", (req, res) => res.render!"index.dt")
        .get("*", serveStaticFiles("public"))
        .post("/github_hook", &githubHook)
        .match(HTTPMethod.HEAD, "/trello_hook", (HTTPServerRequest req, HTTPServerResponse res) => res.writeVoidBody)
        .post("/trello_hook", &trelloHook)
        .post("/codecov_hook", &codecovHook)
        ;

    HTTPClient.setUserAgentString("dlang-bot vibe.d/"~vibeVersionString);

    prThrottler = typeof(prThrottler)(&searchForAutoMergePrs, timeBetweenFullPRChecks);

    listenHTTP(settings, router);
}

//==============================================================================
// Github hook
//==============================================================================

void trelloHook(HTTPServerRequest req, HTTPServerResponse res)
{
    import std.array : array;
    import dlangbot.trello : verifyRequest;

    auto json = verifyRequest(req.headers["X-Trello-Webhook"], req.bodyReader.readAllUTF8, trelloHookURL);
    logDebug("trelloHook: %s", json);
    auto action = json["action"]["type"].get!string;
    switch (action)
    {
    case "createCard", "updateCard":
        auto refs = matchIssueRefs(json["action"]["data"]["card"]["name"].get!string).array;
        auto descs = getDescriptions(refs);
        updateTrelloCard(json["action"]["data"]["card"]["id"].get!string, refs, descs);
        return res.writeBody("handled");
    default:
        return res.writeBody("ignored");
    }
}

void githubHook(HTTPServerRequest req, HTTPServerResponse res)
{
    import std.functional : toDelegate;
    import dlangbot.github : verifyRequest;

    auto json = verifyRequest(req.headers["X-Hub-Signature"], req.bodyReader.readAllUTF8);
    logDebug("githubHook: %s", json);
    switch (req.headers["X-GitHub-Event"])
    {
    case "ping":
        return res.writeBody("pong");

    case "status":
        auto state = json["state"].get!string;
        auto repoSlug = json["name"].get!string;
        logDebug("[github/pull_request](%s): state=%s, sha=%s, url=%s", repoSlug, state, json["sha"], json["target_url"]);
        // no need to trigger the checker for failure/pending
        if (state == "success")
            prThrottler(repoSlug);

        return res.writeBody("handled");

    case "pull_request":
        auto action = json["action"].get!string;
        auto repoSlug = json["repository"]["full_name"].get!string;
        auto pullRequest = json["pull_request"].deserializeJson!PullRequest;
        logInfo("[github/pull_request](%s#%s): action=%s", repoSlug, pullRequest.number, action);

        switch (action)
        {
        case "unlabeled":
            // for now unlabel events are ignored
            return res.writeBody("ignored");
        case "closed":
            if (json["pull_request"]["merged"].get!bool)
                action = "merged";
            goto case;
        case "opened", "reopened", "synchronize", "labeled", "edited":
            if (action == "labeled")
            {
                if (json["label"]["name"].get!string == "bot-rebase")
                {
                    import dlangbot.git : rebase;
                    runTaskHelper(&rebase, &pullRequest);
                    return res.writeBody("handled");
                }
            }
            runTaskHelper(&handlePR, action, &pullRequest);
            return res.writeBody("handled");
        default:
            return res.writeBody("ignored");
        }

    case "pull_request_review":
        auto state = json["review"]["state"].get!string;
        auto repoSlug = json["repository"]["full_name"].get!string;
        auto pullRequest = json["pull_request"].deserializeJson!PullRequest;
        logInfo("[github/pull_request_review](%s#%s): state=%s", repoSlug, pullRequest.number, state);

        runTaskHelper(&handleReview, state, &pullRequest);
        return res.writeBody("handled");

    default:
        return res.writeVoidBody();
    }
}

//==============================================================================

void cronDaily(string[] repositories, CronConfig config)
{
    auto actions = [
        &detectStalledPR,
        &detectInactiveStablePR,
        &detectPRWithMergeConflicts,
        &detectPRWithPersistentCIFailures,
    ];

    foreach (repo; repositories)
    {
        logInfo("[cron-daily/%s]: starting", repo);
        walkPRs(repo, actions, config);
    }
}

//==============================================================================

void handlePR(string action, PullRequest* _pr)
{
    import std.algorithm : among, any;
    import vibe.core.core : setTimer;
    import dlangbot.warnings : checkForWarnings, UserMessage;

    const PullRequest pr = *_pr;

    Json[] commits;

    if (action == "labeled" || action == "synchronize")
    {
        auto labels = pr.labels;
        logDebug("[github/handlePR](%s): labels", labels);
        if (action == "labeled")
        {
            if (auto method = labels.autoMergeMethod)
                commits = pr.tryMerge(method);
            return;
        }
        if (action == "synchronize")
        {
            logDebug("[github/handlePR](%s): checkAndRemoveLabels", _pr.pid);
            enum toRemoveLabels = ["auto-merge", "auto-merge-squash",
                                   "needs rebase", "needs work", "stalled", "stable-stalled"];
            checkAndRemoveLabels(labels, pr, toRemoveLabels);
        }
    }

    if (action == "opened" || action == "edited")
        checkTitleForLabels(pr);

    // we only query the commits once
    if (commits is null)
        commits = ghGetRequest(pr.commitsURL).readJson[];

    auto refs = getIssueRefs(commits);

    auto descs = getDescriptions(refs);
    auto comment = pr.getBotComment;

    UserMessage[] msgs;
    if (action == "opened" || action == "synchronize")
    {
        msgs = pr.checkForWarnings(descs, refs);
    }

    if (pr.base.repo.owner.login.among("dlang", "dlang-bots"))
        pr.updateGithubComment(comment, action, refs, descs, msgs);

    if (refs.any!(r => r.fixed))
    {
        import std.algorithm : canFind, filter, map, sort, uniq;
        import std.array : array;
        // references are already sorted by id
        auto bugzillaIds = refs.map!(r => r.id).uniq;
        auto bugzillSeverities = descs
            .filter!(d => bugzillaIds.canFind(d.id))
            .map!(i => i.severity);
        logDebug("[github/handlePR](%s): trying to add bug fix label", _pr.pid);
        string[] labels;
        if (bugzillSeverities.canFind("enhancement"))
            labels ~= "Enhancement";
        else
            labels ~= "Bug Fix";

        pr.addLabels(labels);
    }

    if (runTrello)
    {
        logDebug("[github/handlePR](%s): updating trello card", _pr.pid);
        updateTrelloCard(action, pr.htmlURL, refs, descs);
    }
}

void handleReview(string action, PullRequest* _pr)
{
    import std.algorithm : among, filter;

    const PullRequest pr = *_pr;

    auto labels = ghGetRequest(pr.labelsURL)
        .readJson
        .deserializeJson!(GHLabel[]);
    if (auto method = autoMergeMethod(labels))
        pr.tryMerge(method);
}

void setBotTimer(C)(Duration dur, C callback)
{
    if (runAsync)
        setTimer(dur, callback);
    else
        callback();
}

//==============================================================================

void codecovHook(HTTPServerRequest req, HTTPServerResponse res)
{
    logDebug("codecovHook: %s", req.bodyReader.readAllUTF8);
    return res.writeBody("OK");
}

//==============================================================================

version (unittest) {}
else void main(string[] args)
{
    import std.array : array;
    import std.algorithm.iteration : map;
    import std.process : environment;
    import vibe.core.args : readOption;

    githubAuth = "token "~environment["GH_TOKEN"];
    trelloSecret = environment["TRELLO_SECRET"];
    trelloAuth = "key="~environment["TRELLO_KEY"]~"&token="~environment["TRELLO_TOKEN"];
    hookSecret = environment["GH_HOOK_SECRET"];

    // workaround for stupid openssl.conf on Heroku
    if (environment.get("DYNO") !is null)
    {
        HTTPClient.setTLSSetupCallback((ctx) {
            ctx.useTrustedCertificateFile("/etc/ssl/certs/ca-certificates.crt");
        });
    }

    bool runDailyCron, runDailyCronSimulation;
    auto settings = new HTTPServerSettings;
    settings.port = 8080;
    readOption("port|p", &settings.port, "Sets the port used for serving.");
    readOption("simulate-cron-daily", &runDailyCronSimulation, "Sets the port used for serving.");
    readOption("cron-daily", &runDailyCron, "Run daily cron tasks.");
    if (!finalizeCommandLineOptions())
        return;

    string[] cronRepositories;
    if (runDailyCron)
    {
        cronRepositories = ["dmd", "druntime", "phobos", "dlang.org", "tools", "installer"]
            .map!(r => "dlang/" ~ r).array;
    }
    else if (runDailyCronSimulation)
    {
        cronRepositories = ["dlang/phobos"];
    }

    if (cronRepositories)
    {
        CronConfig config = {simulate: runDailyCronSimulation};
        return cronDaily(cronRepositories, config);
    }

    startServer(settings);
    lowerPrivileges();
    runEventLoop();
}
