/*
 * termux_ipa_pusher.c
 * Công cụ gốc (Native C trên Android aarch64 Termux) giao tiếp trực tiếp với iPhone
 * qua libimobiledevice + usbmuxd + cáp USB-OTG:
 *   1. status         : Kiểm tra kết nối USB, phiên bản iOS, trạng thái ghép đôi (Trust) & Pairing File
 *   2. export-pairing : Xuất tệp ghép đôi (.mobiledevicepairing / .plist) cho iPhone dùng lâu dài không cần cáp
 *   3. install <ipa>  : Đẩy gói .ipa đã ký qua kênh AFC (/PublicStaging) và kích hoạt mobile_installation_proxy
 *
 * Lưu ý trung thực: Chỉ báo thành công khi phần cứng iPhone thực sự phản hồi qua usbmuxd.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <pthread.h>
#include <sys/stat.h>
#include <unistd.h>

#include <plist/plist.h>
#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
#include <libimobiledevice/afc.h>
#include <libimobiledevice/installation_proxy.h>

#ifndef LOCKDOWN_DIR
#define LOCKDOWN_DIR "/data/data/com.termux/files/usr/var/lib/lockdown"
#endif

typedef struct {
    pthread_mutex_t mutex;
    pthread_cond_t cond;
    int finished;
    int failed;
    char error_name[128];
    char error_desc[512];
} install_waiter_t;

static void get_lockdown_str(lockdownd_client_t client, const char* key, char* out, size_t out_sz) {
    out[0] = '\0';
    plist_t node = NULL;
    if (lockdownd_get_value(client, NULL, key, &node) == LOCKDOWN_E_SUCCESS && node) {
        if (plist_get_node_type(node) == PLIST_STRING) {
            char* val = NULL;
            plist_get_string_val(node, &val);
            if (val) {
                snprintf(out, out_sz, "%s", val);
                free(val);
            }
        }
        plist_free(node);
    }
}

static int cmd_status(void) {
    char** dev_list = NULL;
    int count = 0;
    idevice_error_t derr = idevice_get_device_list(&dev_list, &count);
    if (derr != IDEVICE_E_SUCCESS || count <= 0 || !dev_list) {
        printf("[CHƯA KẾT NỐI] Không tìm thấy iPhone nào trên socket usbmuxd.\n");
        printf("  -> Hãy cắm cáp USB-OTG giữa Android và iPhone rồi chạy ./connect-and-pair.sh\n");
        if (dev_list) idevice_device_list_free(dev_list);
        return 2;
    }

    printf("[PHÁT HIỆN] Tìm thấy %d thiết bị iOS qua usbmuxd:\n", count);
    int rc = 0;

    for (int i = 0; i < count && dev_list[i]; ++i) {
        const char* udid = dev_list[i];
        printf("\n--- Thiết bị #%d ---\n", i + 1);
        printf("  UDID             : %s\n", udid);

        idevice_t dev = NULL;
        if (idevice_new(&dev, udid) != IDEVICE_E_SUCCESS || !dev) {
            printf("  Trạng thái       : Không thể mở phiên idevice_new.\n");
            rc = 1;
            continue;
        }

        lockdownd_client_t lock = NULL;
        lockdownd_error_t lerr = lockdownd_client_new_with_handshake(dev, &lock, "ipa-installer-termux");
        if (lerr != LOCKDOWN_E_SUCCESS || !lock) {
            printf("  Ghép đôi (Trust) : CHƯA TIN CẬY (mã lockdownd=%d).\n", (int)lerr);
            printf("  Hướng dẫn        : Mở khóa màn hình iPhone, nhấn 'Tin cậy' (Trust) và nhập mật mã, sau đó chạy: idevicepair pair\n");
            idevice_free(dev);
            rc = 1;
            continue;
        }

        char dev_name[128], prod_type[64], ios_ver[64], cpu_arch[32];
        get_lockdown_str(lock, "DeviceName", dev_name, sizeof(dev_name));
        get_lockdown_str(lock, "ProductType", prod_type, sizeof(prod_type));
        get_lockdown_str(lock, "ProductVersion", ios_ver, sizeof(ios_ver));
        get_lockdown_str(lock, "CPUArchitecture", cpu_arch, sizeof(cpu_arch));

        printf("  Tên iPhone       : %s\n", dev_name[0] ? dev_name : "(Không rõ)");
        printf("  Model & CPU      : %s (%s)\n", prod_type[0] ? prod_type : "iPhone", cpu_arch[0] ? cpu_arch : "arm64");
        printf("  Phiên bản iOS    : iOS %s\n", ios_ver[0] ? ios_ver : "?");
        printf("  Ghép đôi (Trust) : ĐÃ XÁC THỰC HỢP LỆ (Handshake OK)\n");

        char pair_path[512];
        snprintf(pair_path, sizeof(pair_path), "%s/%s.plist", LOCKDOWN_DIR, udid);
        if (access(pair_path, R_OK) == 0) {
            printf("  Pairing File     : CÓ SẴN (%s)\n", pair_path);
        } else {
            printf("  Pairing File     : Không tìm thấy tại %s\n", pair_path);
        }

        lockdownd_client_free(lock);
        idevice_free(dev);
    }

    idevice_device_list_free(dev_list);
    return rc;
}

static int copy_file_binary(const char* src, const char* dst) {
    FILE* in = fopen(src, "rb");
    if (!in) return -1;
    FILE* out = fopen(dst, "wb");
    if (!out) {
        fclose(in);
        return -1;
    }
    char buf[32768];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), in)) > 0) {
        if (fwrite(buf, 1, n, out) != n) {
            fclose(in);
            fclose(out);
            return -1;
        }
    }
    fclose(in);
    fclose(out);
    return 0;
}

static int cmd_export_pairing(const char* out_dir) {
    char** dev_list = NULL;
    int count = 0;
    if (idevice_get_device_list(&dev_list, &count) != IDEVICE_E_SUCCESS || count <= 0 || !dev_list) {
        fprintf(stderr, "Lỗi: Chưa có iPhone nào kết nối để xuất Pairing File.\n");
        if (dev_list) idevice_device_list_free(dev_list);
        return 1;
    }

    const char* udid = dev_list[0];
    char src_plist[512];
    snprintf(src_plist, sizeof(src_plist), "%s/%s.plist", LOCKDOWN_DIR, udid);
    if (access(src_plist, R_OK) != 0) {
        fprintf(stderr, "Lỗi: Chưa có Pairing File tại %s. Hãy chạy 'idevicepair pair' trước.\n", src_plist);
        idevice_device_list_free(dev_list);
        return 1;
    }

    mkdir(out_dir, 0700);
    char dst_mobile[512];
    snprintf(dst_mobile, sizeof(dst_mobile), "%s/%s.mobiledevicepairing", out_dir, udid);
    if (copy_file_binary(src_plist, dst_mobile) != 0) {
        fprintf(stderr, "Lỗi: Không thể ghi tệp Pairing File sang %s.\n", dst_mobile);
        idevice_device_list_free(dev_list);
        return 1;
    }

    printf("[THÀNH CÔNG] Đã xuất Pairing File cho UDID %s:\n  -> %s\n", udid, dst_mobile);
    printf("  (Lưu ý bảo mật: Tệp này chứa khóa ghép đôi thiết bị — tuyệt đối không chia sẻ công khai!)\n");
    idevice_device_list_free(dev_list);
    return 0;
}

static void instproxy_progress_cb(plist_t command, plist_t status, void* user_data) {
    (void)command;
    install_waiter_t* waiter = (install_waiter_t*)user_data;
    if (!status || !waiter) return;

    int pct = -1;
    instproxy_status_get_percent_complete(status, &pct);

    char* status_name = NULL;
    plist_t st_node = plist_dict_get_item(status, "Status");
    if (st_node && plist_get_node_type(st_node) == PLIST_STRING) {
        plist_get_string_val(st_node, &status_name);
    }

    char* err_name = NULL;
    char* err_desc = NULL;
    uint64_t err_code = 0;
    instproxy_error_t ierr = instproxy_status_get_error(status, &err_name, &err_desc, &err_code);

    pthread_mutex_lock(&waiter->mutex);
    if (ierr != INSTPROXY_E_SUCCESS) {
        waiter->failed = 1;
        waiter->finished = 1;
        snprintf(waiter->error_name, sizeof(waiter->error_name), "%s", err_name ? err_name : "InstallError");
        snprintf(waiter->error_desc, sizeof(waiter->error_desc), "%s", err_desc ? err_desc : "Không rõ chi tiết từ installd");
        pthread_cond_signal(&waiter->cond);
    } else if (status_name && strcmp(status_name, "Complete") == 0) {
        printf("  [100%%] Hoàn tất cài đặt trên iPhone!\n");
        fflush(stdout);
        waiter->finished = 1;
        pthread_cond_signal(&waiter->cond);
    } else if (status_name) {
        if (pct >= 0) {
            printf("  [%3d%%] Trạng thái installd: %s\n", pct, status_name);
        } else {
            printf("  [ .. ] Trạng thái installd: %s\n", status_name);
        }
        fflush(stdout);
    }
    pthread_mutex_unlock(&waiter->mutex);

    if (status_name) free(status_name);
    if (err_name) free(err_name);
    if (err_desc) free(err_desc);
}

static int cmd_install_ipa(const char* ipa_path) {
    struct stat st;
    if (stat(ipa_path, &st) != 0 || st.st_size <= 0) {
        fprintf(stderr, "Lỗi: Không đọc được tệp IPA '%s': %s\n", ipa_path, strerror(errno));
        return 1;
    }

    FILE* fp = fopen(ipa_path, "rb");
    if (!fp) {
        fprintf(stderr, "Lỗi mở tệp IPA: %s\n", strerror(errno));
        return 1;
    }

    idevice_t dev = NULL;
    if (idevice_new(&dev, NULL) != IDEVICE_E_SUCCESS || !dev) {
        fclose(fp);
        fprintf(stderr, "Lỗi: Không tìm thấy iPhone kết nối qua usbmuxd.\n");
        return 1;
    }

    afc_client_t afc = NULL;
    afc_error_t aerr = afc_client_start_service(dev, &afc, "ipa-installer-afc");
    if (aerr != AFC_E_SUCCESS || !afc) {
        idevice_free(dev);
        fclose(fp);
        fprintf(stderr, "Lỗi: Không khởi động được dịch vụ AFC (mã=%d). Kiểm tra lại trạng thái Trust trên iPhone.\n", (int)aerr);
        return 1;
    }

    afc_make_directory(afc, "PublicStaging");

    const char* base = strrchr(ipa_path, '/');
    base = base ? (base + 1) : ipa_path;
    char remote_path[512];
    snprintf(remote_path, sizeof(remote_path), "PublicStaging/%s", base);

    uint64_t afc_handle = 0;
    if (afc_file_open(afc, remote_path, AFC_FOPEN_WRONLY, &afc_handle) != AFC_E_SUCCESS) {
        afc_client_free(afc);
        idevice_free(dev);
        fclose(fp);
        fprintf(stderr, "Lỗi: Không thể tạo tệp '%s' trên iPhone qua AFC.\n", remote_path);
        return 1;
    }

    printf(">>> Đang truyền gói IPA sang iPhone (%lld bytes) -> %s\n", (long long)st.st_size, remote_path);
    char chunk[65536];
    int64_t sent_total = 0;
    int last_pct = -1;
    size_t nread;

    while ((nread = fread(chunk, 1, sizeof(chunk), fp)) > 0) {
        uint32_t written_total = 0;
        while (written_total < (uint32_t)nread) {
            uint32_t w = 0;
            aerr = afc_file_write(afc, afc_handle, chunk + written_total, (uint32_t)nread - written_total, &w);
            if (aerr != AFC_E_SUCCESS) {
                afc_file_close(afc, afc_handle);
                afc_client_free(afc);
                idevice_free(dev);
                fclose(fp);
                fprintf(stderr, "\nLỗi truyền dữ liệu AFC giữa chừng (mã=%d).\n", (int)aerr);
                return 1;
            }
            written_total += w;
        }
        sent_total += (int64_t)nread;
        int pct = (int)((sent_total * 100) / st.st_size);
        if (pct >= last_pct + 10 || sent_total == st.st_size) {
            last_pct = pct;
            printf("  [AFC Upload] %3d%% (%lld / %lld bytes)\n", pct, (long long)sent_total, (long long)st.st_size);
            fflush(stdout);
        }
    }

    fclose(fp);
    afc_file_close(afc, afc_handle);
    afc_client_free(afc);

    instproxy_client_t ipc = NULL;
    instproxy_error_t ierr = instproxy_client_start_service(dev, &ipc, "ipa-installer-proxy");
    if (ierr != INSTPROXY_E_SUCCESS || !ipc) {
        idevice_free(dev);
        fprintf(stderr, "Lỗi: Không thể mở dịch vụ mobile_installation_proxy (mã=%d).\n", (int)ierr);
        return 1;
    }

    printf(">>> Đang yêu cầu iOS installd xác minh chữ ký & cài đặt '%s'...\n", remote_path);
    install_waiter_t waiter;
    memset(&waiter, 0, sizeof(waiter));
    pthread_mutex_init(&waiter.mutex, NULL);
    pthread_cond_init(&waiter.cond, NULL);

    plist_t opts = instproxy_client_options_new();
    ierr = instproxy_upgrade(ipc, remote_path, opts, instproxy_progress_cb, &waiter);
    if (ierr == INSTPROXY_E_SUCCESS) {
        pthread_mutex_lock(&waiter.mutex);
        while (!waiter.finished) {
            pthread_cond_wait(&waiter.cond, &waiter.mutex);
        }
        pthread_mutex_unlock(&waiter.mutex);
    } else {
        waiter.failed = 1;
        snprintf(waiter.error_name, sizeof(waiter.error_name), "InstProxyStartError(%d)", (int)ierr);
        snprintf(waiter.error_desc, sizeof(waiter.error_desc), "Không thể gửi lệnh instproxy_upgrade.");
    }

    instproxy_client_options_free(opts);
    instproxy_client_free(ipc);
    idevice_free(dev);
    pthread_cond_destroy(&waiter.cond);
    pthread_mutex_destroy(&waiter.mutex);

    if (waiter.failed) {
        fprintf(stderr, "\n[CÀI ĐẶT BỊ CHẶN BỞI iOS] %s: %s\n", waiter.error_name, waiter.error_desc);
        fprintf(stderr, "  Gợi ý: Nếu báo ApplicationVerificationFailed, gói IPA chưa được ký bằng chứng chỉ khớp UDID của chiếc iPhone này.\n");
        return 1;
    }

    printf("\n[THÀNH CÔNG] Ứng dụng đã được cài đặt lên màn hình chính iPhone!\n");
    return 0;
}

int main(int argc, char** argv) {
    if (argc < 2) {
        printf("Cách dùng: %s <lệnh> [tham số]\n", argv[0]);
        printf("  status                 : Kiểm tra kết nối iPhone, phiên bản iOS & trạng thái Trust\n");
        printf("  export-pairing <dir>   : Xuất tệp ghép đôi (.mobiledevicepairing) cho iPhone\n");
        printf("  install <signed.ipa>   : Đẩy và cài đặt tệp .ipa đã ký sang iPhone qua USB-OTG\n");
        return 1;
    }

    if (strcmp(argv[1], "status") == 0) {
        return cmd_status();
    }
    if (strcmp(argv[1], "export-pairing") == 0) {
        const char* out_dir = (argc >= 3) ? argv[2] : "./pairing_out";
        return cmd_export_pairing(out_dir);
    }
    if (strcmp(argv[1], "install") == 0) {
        if (argc < 3) {
            fprintf(stderr, "Thiếu đường dẫn tới tệp .ipa đã ký.\n");
            return 1;
        }
        return cmd_install_ipa(argv[2]);
    }

    fprintf(stderr, "Lệnh không hợp lệ: %s\n", argv[1]);
    return 1;
}
