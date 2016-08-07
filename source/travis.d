struct TravisBuildCanceller
{
    import vibe.http.client : HTTPClientRequest, requestHTTP;
    import vibe.web.rest : HTTPMethod;
    import vibe.data.json : Json;
    import vibe.core.log;

    string token;
    private enum buildsPerRequest = 25;

    this(string token)
    {
        if (token.length)
            this.token = "token " ~ token;
    }

    private void setAuth(scope HTTPClientRequest req)
    {
        req.headers["Accept"] = "application/vnd.travis-ci.2+json";
        req.headers["Authorization"] = token;
    }

    private auto getBuilds(string org, string repo, int afterNumber = 0)
    {
        import std.conv : to;
        auto url = "https://api.travis-ci.org/repos/" ~ org ~ "/" ~ repo ~ "/builds";
        if (afterNumber > 0)
            url ~= "?after_number=" ~ afterNumber.to!string;
        return requestHTTP(url, (scope req) {
            setAuth(req);
        }).readJson()["builds"][];
    }

    private bool hasRun(Json obj)
    {
        auto state = obj["state"].get!string;
        return state == "finished" || state == "errored" || state == "passed" || state == "failed" || state == "canceled";
    }

    private void cancelBuild(ulong buildId)
    {
        import std.conv : to;
        logInfo("cancelling: %d", buildId);
        if (token.length)
        {
            auto url = "https://api.travis-ci.org/builds/" ~ buildId.to!string ~ "/cancel";
            requestHTTP(url, (scope req) {
                req.method = HTTPMethod.POST;
                setAuth(req);
            }, (scope res) {
                logInfo("cancelled: %d", buildId);
            });
        }
    }

    void run(string org, string repo)
    {
        import std.stdio;
        import std.algorithm;
        import std.array : byPair;
        import std.range : array;

        Json[] builds;
        Json[][ulong] prsDict;

        // we might need to query multiple pages
        for (;;)
        {
            auto receivedBuilds = 0;
            foreach (build; getBuilds(org, repo).filter!(x => !hasRun(x)))
            {
                auto prNumber = build["pull_request_number"].get!int;
                if (prNumber > 0)
                    prsDict[prNumber] ~= build;
                receivedBuilds++;
            }
            logInfo("fetching ...%d", receivedBuilds);
            // query until at least one run job is found
            if (receivedBuilds < buildsPerRequest)
                break;
        }

        // loop over all prs and find the ones that have more than one build running
        // -> cancel those
        foreach (key, prs; prsDict.byPair)
        {
            if (prs.length > 1)
            {
                auto toCancel = prs[1..$];
                toCancel.map!`a["id"].get!ulong`.each!(a => cancelBuild(a));
            }
            else
            {
                logInfo("Only one job running for PR #%d", key);
            }
        }
    }
}
