// Instrumented-test-only ContentProvider granting synthetic document URIs to the target app under
// test, without bypassing real SAF permission grants; paired with WorkspaceTestDocuments.java.

package com.personalailabs.astraldeep.app.workspace;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.net.Uri;
import android.os.Binder;
import android.os.Bundle;
import android.provider.DocumentsContract;
import java.io.FileNotFoundException;
import java.util.HashSet;
import java.util.Set;

public final class WorkspaceTestDocumentsControl extends ContentProvider {
    private static final String TARGET = "com.personalailabs.astraldeep";
    private static final String DOCUMENTS = "com.personalailabs.astraldeep.test.workspace.documents";
    private static final int GRANTS = Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION;
    private final Set<Uri> grants = new HashSet<>();

    @Override public boolean onCreate() { return true; }

    @Override public synchronized Bundle call(String method, String arg, Bundle extras) {
        Context context = getContext();
        if (context == null) throw new IllegalStateException("Synthetic provider unavailable");
        int caller = Binder.getCallingUid();
        try {
            PackageManager packages = context.getPackageManager();
            if (caller != packages.getApplicationInfo(TARGET, 0).uid
                    || packages.checkSignatures(caller, context.getApplicationInfo().uid) != PackageManager.SIGNATURE_MATCH) {
                throw new SecurityException("Synthetic document control caller refused");
            }
        } catch (PackageManager.NameNotFoundException missing) {
            throw new SecurityException("Synthetic document target missing");
        }
        if (extras != null) throw new IllegalArgumentException("Unexpected synthetic extras");
        long identity = Binder.clearCallingIdentity();
        try {
            if ("test-create".equals(method)) {
                if (arg == null || !arg.matches("[a-zA-Z0-9-]{1,64}")) throw new IllegalArgumentException("Invalid synthetic name");
                Uri uri = DocumentsContract.createDocument(context.getContentResolver(),
                        DocumentsContract.buildDocumentUri(DOCUMENTS, "root"), "text/html", arg);
                if (uri == null) throw new IllegalStateException("Synthetic document unavailable");
                context.grantUriPermission(TARGET, uri, GRANTS);
                grants.add(uri);
                Bundle result = new Bundle();
                result.putString("uri", uri.toString());
                return result;
            }
            if ("test-reset".equals(method) && arg == null) {
                try {
                    return context.getContentResolver().call(DOCUMENTS, method, null, null);
                } finally {
                    for (Uri uri : grants) context.revokeUriPermission(TARGET, uri, GRANTS);
                    grants.clear();
                }
            }
            if (("test-status".equals(method) || "test-release".equals(method))
                    && arg != null && arg.matches("[a-zA-Z0-9-]{1,128}")) {
                return context.getContentResolver().call(DOCUMENTS, method, arg, null);
            }
            throw new IllegalArgumentException("Unknown synthetic document control");
        } catch (FileNotFoundException failure) {
            throw new IllegalStateException("Synthetic create failed", failure);
        } finally {
            Binder.restoreCallingIdentity(identity);
        }
    }

    @Override public Cursor query(Uri uri, String[] projection, String selection, String[] args, String order) {
        throw new UnsupportedOperationException("Synthetic control supports calls only");
    }
    @Override public String getType(Uri uri) { throw new UnsupportedOperationException("Synthetic control supports calls only"); }
    @Override public Uri insert(Uri uri, ContentValues values) { throw new UnsupportedOperationException("Synthetic control supports calls only"); }
    @Override public int update(Uri uri, ContentValues values, String selection, String[] args) { throw new UnsupportedOperationException("Synthetic control supports calls only"); }
    @Override public int delete(Uri uri, String selection, String[] args) { throw new UnsupportedOperationException("Synthetic control supports calls only"); }
}
