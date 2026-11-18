package com.github.catvod.crawler;

/** Do not forward remote spider messages, URLs or credentials to host logs. */
public final class SpiderDebug {
    public static void log(String message) { }
    public static void log(Throwable error) { }
    public static void log(Object message) { }
}
