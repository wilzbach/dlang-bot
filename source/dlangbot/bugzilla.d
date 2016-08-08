module dlangbot.bugzilla;

import dlangbot.github : githubAuth;
import dlangbot.issue;
import std.algorithm, std.range;
import vibe.data.json;
import vibe.http.client : requestHTTP;

//==============================================================================
// Bugzilla
//==============================================================================

auto matchIssueRefs(string message)
{
    import std.regex;
    static auto matchToRefs(M)(M m)
    {
        import std.string : stripRight;
        import std.conv : to;
        auto closed = !m.captures[1].empty;
        import std.stdio;
        return m.captures[5].stripRight.splitter(ctRegex!`[^\d]+`)
                .map!(id => IssueRef(id.to!int, closed));
    }

    // see https://github.com/github/github-services/blob/2e886f407696261bd5adfc99b16d36d5e7b50241/lib/services/bugzilla.rb#L155
    enum issueRE = ctRegex!(`((close|fix|address)e?(s|d)? )?(ticket|bug|tracker item|issue)s?:? *([\d ,\+&#and]+)`, "i");
    return message.matchAll(issueRE).map!matchToRefs.joiner;
}

unittest
{
    import std.algorithm.comparison : equal;
    assert(matchIssueRefs("Fix issue 42").equal([IssueRef(42, true)]));
    assert(matchIssueRefs("Closes bug 142").equal([IssueRef(142, true)]));
    assert(matchIssueRefs("Close ticket 2042").equal([IssueRef(2042, true)]));
    assert(matchIssueRefs("Close ticket 2042, 2043")
            .equal([IssueRef(2042, true), IssueRef(2043, true)]));

    // TODO: how should this be handled?
    import std.exception :assertThrown;
    assertThrown!Exception(matchIssueRefs("Fix issue #42").front);
}

// get all issues mentioned in a commit
IssueRef[] getIssueRefs(string commitsURL)
{
    import std.array : array;
    auto issues = requestHTTP(commitsURL, (scope req) { req.headers["Authorization"] = githubAuth; })
        .readJson[]
        .map!(c => c["commit"]["message"].get!string.matchIssueRefs)
        .joiner
        .array;
    issues.multiSort!((a, b) => a.id < b.id, (a, b) => a.fixed > b.fixed);
    issues.length -= issues.uniq!((a, b) => a.id == b.id).copy(issues).length;
    return issues;
}

// get pairs of (issue number, short descriptions) from bugzilla
Issue[] getDescriptions(R)(R issueRefs)
{
    import std.csv;
    import std.format : format;
    import vibe.stream.operations : readAllUTF8;

    if (issueRefs.empty)
        return null;
    return "https://issues.dlang.org/buglist.cgi?bug_id=%(%d,%)&ctype=csv&columnlist=short_desc"
        .format(issueRefs.map!(r => r.id))
        .requestHTTP
        .bodyReader.readAllUTF8
        .csvReader!Issue(null)
        .array
        .sort!((a, b) => a.id < b.id)
        .release;
}
