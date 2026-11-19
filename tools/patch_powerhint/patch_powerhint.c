/*
 * Dynamic PowerHAL powerhint.json Patcher
 * Author: Kana Wesley Yamada
 *
 * Automatically inspects and patches the ROM's live powerhint.json at boot
 * to eliminate aggressive touch-boost power drain while preserving 100% of the
 * ROM maintainer's custom hints, camera profiles, and thermal limits.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "cJSON.h"

static char *read_file(const char *path, size_t *out_size) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz <= 0) { fclose(f); return NULL; }

    char *buf = malloc(sz + 1);
    if (!buf) { fclose(f); return NULL; }
    size_t rd = fread(buf, 1, sz, f);
    buf[rd] = '\0';
    fclose(f);
    if (out_size) *out_size = rd;
    return buf;
}

static int write_file(const char *path, const char *data) {
    FILE *f = fopen(path, "wb");
    if (!f) return -1;
    size_t len = strlen(data);
    size_t wr = fwrite(data, 1, len, f);
    fclose(f);
    return (wr == len) ? 0 : -1;
}

static void patch_freq_node(cJSON *node, const char *nm) {
    cJSON *values = cJSON_GetObjectItem(node, "Values");
    if (!cJSON_IsArray(values)) return;

    int sz = cJSON_GetArraySize(values);
    if (sz == 0) return;

    /* Remove legacy 200000 if present */
    for (int i = sz - 1; i >= 0; i--) {
        cJSON *it = cJSON_GetArrayItem(values, i);
        if (cJSON_IsString(it) && strcmp(it->valuestring, "200000") == 0) {
            cJSON_DeleteItemFromArray(values, i);
        }
    }
    sz = cJSON_GetArraySize(values);

    /* Check if 450000 is already present */
    for (int i = 0; i < sz; i++) {
        cJSON *it = cJSON_GetArrayItem(values, i);
        if (cJSON_IsString(it) && strcmp(it->valuestring, "450000") == 0) {
            return; /* already present */
        }
    }

    /* Check ordering: descending vs ascending */
    cJSON *first = cJSON_GetArrayItem(values, 0);
    cJSON *last = cJSON_GetArrayItem(values, sz - 1);
    long v_first = (first && cJSON_IsString(first)) ? atol(first->valuestring) : 0;
    long v_last  = (last  && cJSON_IsString(last))  ? atol(last->valuestring)  : 0;

    int is_min_node = (strstr(nm, "MinFreq") != NULL);

    if (v_first >= v_last) {
        /* Descending: highest frequency first, floor is at the end */
        cJSON_AddItemToArray(values, cJSON_CreateString("450000"));
        if (is_min_node) {
            cJSON_ReplaceItemInObject(node, "DefaultIndex", cJSON_CreateNumber(sz));
        }
    } else {
        /* Ascending: lowest frequency first, floor is at index 0 */
        cJSON_InsertItemInArray(values, 0, cJSON_CreateString("450000"));
        if (is_min_node) {
            cJSON_ReplaceItemInObject(node, "DefaultIndex", cJSON_CreateNumber(0));
        }
    }
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "Usage: %s <input_powerhint.json> <output_powerhint.json>\n", argv[0]);
        return 1;
    }

    const char *in_path = argv[1];
    const char *out_path = argv[2];

    size_t sz = 0;
    char *content = read_file(in_path, &sz);
    if (!content) {
        fprintf(stderr, "[-] Failed to read input file: %s\n", in_path);
        return 1;
    }

    cJSON *root = cJSON_Parse(content);
    free(content);
    if (!root) {
        fprintf(stderr, "[-] JSON parse error in: %s\n", in_path);
        return 1;
    }

    /* 1. Patch Nodes array to ensure 200000 (200 MHz) is recognized across CPU nodes */
    cJSON *nodes = cJSON_GetObjectItem(root, "Nodes");
    if (cJSON_IsArray(nodes)) {
        int n_sz = cJSON_GetArraySize(nodes);
        for (int i = 0; i < n_sz; i++) {
            cJSON *node = cJSON_GetArrayItem(nodes, i);
            cJSON *name = cJSON_GetObjectItem(node, "Name");
            if (!cJSON_IsString(name)) continue;

            const char *nm = name->valuestring;
            if (strcmp(nm, "CPUEfficiencyClusterMinFreq") == 0 ||
                strcmp(nm, "CPUEfficiencyClusterMaxFreq") == 0 ||
                strcmp(nm, "CPUSuperClusterMinFreq") == 0 ||
                strcmp(nm, "CPUSuperClusterMaxFreq") == 0) {
                patch_freq_node(node, nm);
            }
        }
    }

    /* 2. Patch Actions array: sanitize touch-boost power hints (INTERACTION, TOUCH, TAP) */
    cJSON *actions = cJSON_GetObjectItem(root, "Actions");
    if (cJSON_IsArray(actions)) {
        int a_sz = cJSON_GetArraySize(actions);
        /* Traverse backwards so deletions do not invalidate remaining indices */
        for (int i = a_sz - 1; i >= 0; i--) {
            cJSON *action = cJSON_GetArrayItem(actions, i);
            cJSON *hint = cJSON_GetObjectItem(action, "PowerHint");
            if (!cJSON_IsString(hint)) continue;

            const char *h_str = hint->valuestring;
            if (strcmp(h_str, "INTERACTION") != 0 &&
                strcmp(h_str, "TOUCH") != 0 &&
                strcmp(h_str, "TAP") != 0) {
                continue; /* Leave all other hints (LAUNCH, CAMERA, AUDIO, etc.) untouched */
            }

            cJSON *node = cJSON_GetObjectItem(action, "Node");
            if (!cJSON_IsString(node)) continue;
            const char *nm = node->valuestring;

            /* Strip GPU level 0 boost on touch (prevents Mali-G57 1068 MHz spike) */
            if (strcmp(nm, "GpuPwrLevel") == 0) {
                cJSON_DeleteItemFromArray(actions, i);
                continue;
            }

            /* Strip Big CPU cluster min frequency clamp on touch (prevents Cortex-A76 1.44 GHz wake) */
            if (strcmp(nm, "CPUSuperClusterMinFreq") == 0) {
                cJSON_DeleteItemFromArray(actions, i);
                continue;
            }

            /* Strip cluster max freq caps on touch if present */
            if (strcmp(nm, "CPUEfficiencyClusterMaxFreq") == 0 ||
                strcmp(nm, "CPUSuperClusterMaxFreq") == 0) {
                cJSON_DeleteItemFromArray(actions, i);
                continue;
            }

            /* Little core touch boost: clamp duration to 100ms @ 703MHz (OPP 13) */
            if (strcmp(nm, "CPUEfficiencyClusterMinFreq") == 0) {
                cJSON_ReplaceItemInObject(action, "Duration", cJSON_CreateNumber(100));
                cJSON_ReplaceItemInObject(action, "Value", cJSON_CreateString("703000"));
                continue;
            }

            /* Clamp uclamp durations to 150ms */
            if (strcmp(nm, "TAUclampMin") == 0) {
                cJSON_ReplaceItemInObject(action, "Duration", cJSON_CreateNumber(150));
                cJSON_ReplaceItemInObject(action, "Value", cJSON_CreateString("20"));
                continue;
            }
            if (strcmp(nm, "FGUclampMin") == 0) {
                cJSON_ReplaceItemInObject(action, "Duration", cJSON_CreateNumber(150));
                cJSON_ReplaceItemInObject(action, "Value", cJSON_CreateString("10"));
                continue;
            }

            /* Interconnect CCI boost: reduce to 100ms */
            if (strcmp(nm, "CciFreq") == 0) {
                cJSON_ReplaceItemInObject(action, "Duration", cJSON_CreateNumber(100));
                continue;
            }
        }
    }

    /* 3. Output formatted JSON */
    char *out_str = cJSON_Print(root);
    cJSON_Delete(root);

    if (!out_str) {
        fprintf(stderr, "[-] Failed to serialize JSON\n");
        return 1;
    }

    if (write_file(out_path, out_str) != 0) {
        fprintf(stderr, "[-] Failed to write output file: %s\n", out_path);
        free(out_str);
        return 1;
    }

    free(out_str);
    printf("[+] Successfully patched powerhint: %s -> %s\n", in_path, out_path);
    return 0;
}
