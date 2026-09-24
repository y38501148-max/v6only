package edu.buaa.v6only.tests;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;

/** InputStream.transferTo is unavailable before Android 13. */
final class TestIo {
    static void copy(InputStream in, OutputStream out) throws IOException {
        byte[] buffer = new byte[8192];
        for (int n; (n = in.read(buffer)) != -1;) out.write(buffer, 0, n);
    }
}
