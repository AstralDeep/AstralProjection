import java.io.File;
import java.io.InputStream;
import java.nio.file.Files;
import java.util.HashMap;
import java.util.Map;
import java.util.zip.ZipFile;
import org.jacoco.core.data.ExecutionData;
import org.jacoco.core.internal.data.CRC64;
import org.jacoco.core.tools.ExecFileLoader;
import org.objectweb.asm.ClassReader;

/** Refuses stale probes before the pinned native AGP reporter consumes them. */
public final class ValidateClassIds {
    private static void add(Map<String, Long> classes, byte[] bytes) {
        String name = new ClassReader(bytes).getClassName();
        long id = CRC64.classId(bytes);
        Long previous = classes.putIfAbsent(name, id);
        if (previous != null && previous.longValue() != id) {
            throw new IllegalStateException("duplicate_class_id");
        }
    }

    private static void read(Map<String, Long> classes, File input) throws Exception {
        if (!input.exists()) throw new IllegalStateException("class_input_missing");
        if (input.isDirectory()) {
            try (java.util.stream.Stream<java.nio.file.Path> paths = Files.walk(input.toPath())) {
                for (java.nio.file.Path path : paths.filter(p -> p.toString().endsWith(".class")).toList()) {
                    add(classes, Files.readAllBytes(path));
                }
            }
        } else if (input.getName().endsWith(".class")) {
            add(classes, Files.readAllBytes(input.toPath()));
        } else {
            try (ZipFile archive = new ZipFile(input)) {
                for (var entry : java.util.Collections.list(archive.entries())) {
                    if (entry.getName().endsWith(".class")) {
                        try (InputStream stream = archive.getInputStream(entry)) {
                            add(classes, stream.readAllBytes());
                        }
                    }
                }
            }
        }
    }

    public static void main(String[] args) throws Exception {
        int split = java.util.Arrays.asList(args).indexOf("--");
        if (split < 1 || split == args.length - 1) {
            throw new IllegalArgumentException("execution_and_class_inputs_required");
        }
        Map<String, Long> classes = new HashMap<>();
        for (int i = split + 1; i < args.length; i++) read(classes, new File(args[i]));
        if (classes.isEmpty()) throw new IllegalStateException("empty_class_domain");
        StringBuilder lanes = new StringBuilder();
        for (int i = 0; i < split; i++) {
            ExecFileLoader loader = new ExecFileLoader();
            loader.load(new File(args[i]));
            int matched = 0, probes = 0;
            for (ExecutionData data : loader.getExecutionDataStore().getContents()) {
                Long expected = classes.get(data.getName());
                // Test and dependency probes are not in AGP's app class domain.
                if (expected == null) continue;
                if (expected.longValue() != data.getId()) {
                    throw new IllegalStateException("class_id_mismatch");
                }
                matched++;
                for (boolean covered : data.getProbes()) if (covered) probes++;
            }
            if (matched == 0 || probes == 0) throw new IllegalStateException("empty_execution_lane");
            if (i > 0) lanes.append(',');
            lanes.append("{\"classes\":").append(matched)
                .append(",\"hit_probes\":").append(probes).append('}');
        }
        System.out.println("{\"class_domain\":" + classes.size()
            + ",\"mismatches\":0,\"lanes\":[" + lanes + "]}");
    }
}
