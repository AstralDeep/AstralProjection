package com.personalailabs.astraldeep.app.workspace;

import android.database.Cursor;
import android.database.MatrixCursor;
import android.os.Bundle;
import android.os.CancellationSignal;
import android.os.ParcelFileDescriptor;
import android.provider.DocumentsContract.Document;
import android.provider.DocumentsProvider;
import java.io.File;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.IOException;
import java.util.UUID;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/** Test APK only; framework/Java dependencies allow Android's separate provider process. */
public final class WorkspaceTestDocuments extends DocumentsProvider {
    private final ConcurrentHashMap<String, CountDownLatch> gates = new ConcurrentHashMap<>();
    private final Set<String> opened = ConcurrentHashMap.newKeySet();

    private File directory() {
        File dir = new File(getContext().getCacheDir(), "controller-documents");
        if (!dir.isDirectory() && !dir.mkdirs()) throw new IllegalStateException("Synthetic directory unavailable");
        return dir;
    }

    private File file(String id) {
        if (id == null || !id.matches("[a-zA-Z0-9-]+")) throw new IllegalArgumentException("Invalid synthetic ID");
        return new File(directory(), id);
    }

    @Override public boolean onCreate() { return true; }

    @Override public Cursor queryRoots(String[] projection) {
        return new MatrixCursor(projection == null ? new String[]{"root_id"} : projection);
    }

    @Override public Cursor queryChildDocuments(String parent, String[] projection, String sortOrder) {
        return new MatrixCursor(projection == null ? new String[]{Document.COLUMN_DOCUMENT_ID} : projection);
    }

    @Override public Cursor queryDocument(String id, String[] projection) {
        String[] columns = projection == null ? new String[]{Document.COLUMN_DOCUMENT_ID,
                Document.COLUMN_DISPLAY_NAME, Document.COLUMN_SIZE, Document.COLUMN_MIME_TYPE} : projection;
        MatrixCursor cursor = new MatrixCursor(columns);
        File source = file(id);
        if (source.exists()) {
            MatrixCursor.RowBuilder row = cursor.newRow();
            for (String column : columns) {
                switch (column) {
                    case Document.COLUMN_DOCUMENT_ID:
                    case Document.COLUMN_DISPLAY_NAME: row.add(id); break;
                    case Document.COLUMN_SIZE: row.add(source.length()); break;
                    case Document.COLUMN_MIME_TYPE: row.add("text/html"); break;
                    case Document.COLUMN_FLAGS: row.add(Document.FLAG_SUPPORTS_WRITE | Document.FLAG_SUPPORTS_DELETE); break;
                    default: row.add(null);
                }
            }
        }
        return cursor;
    }

    @Override public String createDocument(String parent, String type, String name) throws FileNotFoundException {
        String id = name + "-" + UUID.randomUUID();
        try {
            if (!file(id).createNewFile()) throw new IOException("Synthetic collision");
        } catch (IOException failure) {
            throw new FileNotFoundException("Synthetic create failed");
        }
        return id;
    }

    @Override public ParcelFileDescriptor openDocument(String id, String mode, CancellationSignal signal) throws FileNotFoundException {
        opened.add(id);
        if (mode.contains("w") && id.startsWith("refuse-")) throw new FileNotFoundException("Synthetic open refusal");
        if (mode.contains("w") && id.startsWith("paused-")) {
            try {
                ParcelFileDescriptor[] pipe = ParcelFileDescriptor.createReliablePipe();
                CountDownLatch gate = new CountDownLatch(1);
                gates.put(id, gate);
                Thread reader = new Thread(() -> {
                    try (ParcelFileDescriptor.AutoCloseInputStream input = new ParcelFileDescriptor.AutoCloseInputStream(pipe[0]);
                         FileOutputStream output = new FileOutputStream(file(id))) {
                        byte[] buffer = new byte[1024];
                        int count = input.read(buffer);
                        if (count > 0) output.write(buffer, 0, count);
                        output.flush();
                        if (!gate.await(15, TimeUnit.SECONDS)) return;
                        while ((count = input.read(buffer)) >= 0) output.write(buffer, 0, count);
                    } catch (InterruptedException failure) {
                        Thread.currentThread().interrupt();
                    } catch (IOException expectedWhenCancelled) {
                        // The cancellation fixture deliberately closes an in-flight pipe.
                    }
                }, "synthetic-document-copy");
                reader.setDaemon(true);
                reader.start();
                return pipe[1];
            } catch (IOException failure) {
                throw new FileNotFoundException("Synthetic pipe failed");
            }
        }
        return ParcelFileDescriptor.open(file(id), ParcelFileDescriptor.parseMode(mode));
    }

    @Override public void deleteDocument(String id) {
        CountDownLatch gate = gates.remove(id);
        if (gate != null) gate.countDown();
        file(id).delete();
    }

    @Override public Bundle call(String method, String arg, Bundle extras) {
        if ("test-status".equals(method)) {
            Bundle value = new Bundle();
            value.putBoolean("exists", file(arg).exists());
            value.putBoolean("opened", opened.contains(arg));
            value.putLong("size", file(arg).length());
            return value;
        }
        if ("test-release".equals(method)) {
            CountDownLatch gate = gates.get(arg);
            if (gate != null) gate.countDown();
            return Bundle.EMPTY;
        }
        if ("test-reset".equals(method)) {
            for (CountDownLatch gate : gates.values()) gate.countDown();
            gates.clear();
            opened.clear();
            File[] files = directory().listFiles();
            if (files != null) for (File value : files) value.delete();
            return Bundle.EMPTY;
        }
        return super.call(method, arg, extras);
    }
}
