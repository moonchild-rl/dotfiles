# BDFR - Pin PRAW Version

If **Bulk Downloader for Reddit (BDFR)** fails, it may be because the installed version of `praw` is too new.

BDFR works with praw 7.7.1.

Install or downgrade PRAW with:

```bash
pip install praw==7.7.1
```

Check the installed version:

```bash
pip show praw
```

**Reason:** Newer PRAW versions can be incompatible with BDFR, so keep PRAW pinned to `7.7.1` if the problem occurs again.
