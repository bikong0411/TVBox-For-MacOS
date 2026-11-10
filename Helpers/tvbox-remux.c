#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/error.h>
#include <libavutil/time.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dirent.h>
#include <limits.h>

static volatile sig_atomic_t stopping = 0;
static int64_t deadline = 0;
static pid_t owner_pid = 0;
static void signal_stop(int value) { (void)value; stopping = 1; }
static int interrupted(void *opaque) {
    (void)opaque;
    if (owner_pid && getppid() != owner_pid) stopping = 1;
    return stopping || (deadline && av_gettime_relative() > deadline);
}
static void cleanup_session(const char *output) {
    char directory[PATH_MAX];
    if (strlen(output) >= sizeof(directory)) return;
    strcpy(directory, output);
    char *slash = strrchr(directory, '/'); if (!slash) return; *slash = 0;
    const char *leaf = strrchr(directory, '/'); leaf = leaf ? leaf + 1 : directory;
    if (strncmp(leaf, "tvbox-live-", 11)) return;
    DIR *handle = opendir(directory); if (!handle) return;
    struct dirent *entry;
    while ((entry = readdir(handle))) {
        if (strncmp(entry->d_name, "index", 5) && strcmp(entry->d_name, "error.log")) continue;
        char path[PATH_MAX];
        if (snprintf(path, sizeof(path), "%s/%s", directory, entry->d_name) < (int)sizeof(path)) unlink(path);
    }
    closedir(handle); rmdir(directory);
}
static void report(const char *step, int code) {
    char text[AV_ERROR_MAX_STRING_SIZE];
    av_strerror(code, text, sizeof(text));
    // Deliberately omit URLs and header values from diagnostics.
    fprintf(stderr, "%s (%d): %s\n", step, code, text);
}

int main(int argc, char **argv) {
    if (argc != 4) { fprintf(stderr, "Usage: tvbox-remux INPUT_URL OUTPUT_M3U8 HTTP_HEADERS\n"); return 2; }
    signal(SIGTERM, signal_stop); signal(SIGINT, signal_stop);
    owner_pid = getppid();
    av_log_set_level(AV_LOG_QUIET);
    avformat_network_init();
    AVFormatContext *input = avformat_alloc_context(), *output = NULL;
    AVDictionary *input_options = NULL, *output_options = NULL;
    AVPacket *packet = av_packet_alloc();
    int *mapping = NULL, result = 0, wrote_header = 0;
    if (!input || !packet) { result = AVERROR(ENOMEM); goto done; }
    input->interrupt_callback = (AVIOInterruptCB){interrupted, NULL};
    av_dict_set(&input_options, "protocol_whitelist", "file,http,https,httpproxy,tcp,tls,crypto", 0);
    av_dict_set(&input_options, "tls_verify", "1", 0);
    av_dict_set(&input_options, "rw_timeout", "15000000", 0);
    if (argv[3][0]) av_dict_set(&input_options, "headers", argv[3], 0);
    deadline = av_gettime_relative() + 20000000;
    result = avformat_open_input(&input, argv[1], NULL, &input_options);
    if (result < 0) { report("INPUT_OPEN", result); goto done; }
    deadline = av_gettime_relative() + 20000000;
    result = avformat_find_stream_info(input, NULL);
    if (result < 0) { report("STREAM_INFO", result); goto done; }
    result = avformat_alloc_output_context2(&output, NULL, "hls", argv[2]);
    if (result < 0 || !output) { report("OUTPUT_CREATE", result); goto done; }
    mapping = av_malloc_array(input->nb_streams, sizeof(*mapping));
    if (!mapping) { result = AVERROR(ENOMEM); goto done; }
    int video_count = 0, audio_count = 0;
    for (unsigned int i = 0; i < input->nb_streams; i++) {
        AVCodecParameters *parameters = input->streams[i]->codecpar;
        mapping[i] = -1;
        if (parameters->codec_type == AVMEDIA_TYPE_VIDEO && !video_count) {
            if (parameters->codec_id != AV_CODEC_ID_H264 && parameters->codec_id != AV_CODEC_ID_HEVC) {
                result = AVERROR(ENOSYS); report("VIDEO_CODEC_NOT_SUPPORTED", result); goto done;
            }
            video_count++;
        } else if (parameters->codec_type == AVMEDIA_TYPE_AUDIO && !audio_count) {
            if (parameters->codec_id != AV_CODEC_ID_AAC && parameters->codec_id != AV_CODEC_ID_MP3 && parameters->codec_id != AV_CODEC_ID_AC3) continue;
            audio_count++;
        } else continue;
        AVStream *stream = avformat_new_stream(output, NULL);
        if (!stream) { result = AVERROR(ENOMEM); goto done; }
        result = avcodec_parameters_copy(stream->codecpar, parameters);
        if (result < 0) goto done;
        stream->codecpar->codec_tag = 0;
        stream->time_base = input->streams[i]->time_base;
        mapping[i] = stream->index;
    }
    if (!video_count && !audio_count) { result = AVERROR_STREAM_NOT_FOUND; report("NO_SUPPORTED_STREAM", result); goto done; }
    output->avoid_negative_ts = AVFMT_AVOID_NEG_TS_MAKE_ZERO;
    av_dict_set(&output_options, "hls_time", "2", 0);
    av_dict_set(&output_options, "hls_list_size", "6", 0);
    av_dict_set(&output_options, "hls_delete_threshold", "3", 0);
    av_dict_set(&output_options, "hls_flags", "delete_segments+independent_segments+temp_file", 0);
    result = avformat_write_header(output, &output_options);
    if (result < 0) { report("OUTPUT_HEADER", result); goto done; }
    wrote_header = 1;
    while (!stopping) {
        deadline = av_gettime_relative() + 15000000;
        result = av_read_frame(input, packet);
        if (result < 0) break;
        const int source_index = packet->stream_index;
        if (source_index < 0 || (unsigned)source_index >= input->nb_streams || mapping[source_index] < 0) { av_packet_unref(packet); continue; }
        AVStream *source = input->streams[source_index];
        AVStream *destination = output->streams[mapping[source_index]];
        packet->stream_index = mapping[source_index];
        av_packet_rescale_ts(packet, source->time_base, destination->time_base);
        packet->pos = -1;
        result = av_interleaved_write_frame(output, packet);
        av_packet_unref(packet);
        if (result < 0) { report("WRITE_SEGMENT", result); break; }
    }
    if (result == AVERROR_EOF || stopping) result = 0;
    if (result < 0) report("READ_STREAM", result);
done:
    if (wrote_header) av_write_trailer(output);
    av_dict_free(&input_options); av_dict_free(&output_options);
    av_free(mapping); av_packet_free(&packet);
    avformat_close_input(&input); avformat_free_context(output);
    avformat_network_deinit();
    if (stopping) cleanup_session(argv[2]);
    return result < 0 ? 1 : 0;
}
