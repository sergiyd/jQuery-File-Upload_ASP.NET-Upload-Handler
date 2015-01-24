<%@ WebHandler Language="C#" Class="Handler" %>

using System;
using System.Web;
using System.Collections.Generic;
using System.IO;
using System.Runtime.Serialization;

// app.js
/*
     var isOnGitHub = window.location.hostname === 'blueimp.github.io',
        url = 'server/asp_net/Handler.ashx'; 
 */

//main.js
/*
    // Initialize the jQuery File Upload widget:
    $('#fileupload').fileupload({
        // Uncomment the following to send cross-domain cookies:
        //xhrFields: {withCredentials: true},
        url: 'server/asp_net/Handler.ashx'
    });
 */

public class Handler : IHttpAsyncHandler
{
    private static readonly FilesDisposition FILES_DISPOSITION = FilesDisposition.Absolute;
    private static readonly string FILES_PATH = @"c:\temp\uploader";

    private static readonly string FILE_QUERY_VAR = "file";
    private static readonly string FILE_GET_CONTENT_TYPE = "application/octet-stream";

    private static readonly int ATTEMPTS_TO_WRITE = 3;
    private static readonly int ATTEMPT_WAIT = 100; //msec

    private static readonly int BUFFER_SIZE = 4 * 1024 * 1024;

    private enum FilesDisposition
    {
        ServerRoot,
        HandlerRoot,
        Absolute
    }

    private static class HttpMethods
    {
        public static readonly string GET = "GET";
        public static readonly string POST = "POST";
        public static readonly string DELETE = "DELETE";
    }

    [DataContract]
    private class FileResponse
    {
        [DataMember]
        public string name;
        [DataMember]
        public long size;
        [DataMember]
        public string type;
        [DataMember]
        public string url;
        [DataMember]
        public string error;
        [DataMember]
        public string deleteUrl;
        [DataMember]
        public string deleteType;
    }

    [DataContract]
    private class UploaderResponse
    {
        [DataMember]
        public FileResponse[] files;

        public UploaderResponse(FileResponse[] fileResponses)
        {
            files = fileResponses;
        }
    }

    private static string CreateFileUrl(HttpRequest request, string fileName, FilesDisposition filesDisposition)
    {
        switch (filesDisposition)
        {
            case FilesDisposition.ServerRoot:
                // 1. files directory lies in root directory catalog WRONG
                return String.Format("{0}{1}/{2}", request.Url.GetLeftPart(UriPartial.Authority),
                    FILES_PATH, Path.GetFileName(fileName));

            case FilesDisposition.HandlerRoot:
                // 2. files directory lays in current page catalog WRONG
                return String.Format("{0}{1}{2}/{3}", request.Url.GetLeftPart(UriPartial.Authority),
                    Path.GetDirectoryName(request.CurrentExecutionFilePath).Replace(@"\", @"/"), FILES_PATH, Path.GetFileName(fileName));

            case FilesDisposition.Absolute:
                // 3. files directory lays anywhere YEAH
                return String.Format("{0}?{1}={2}", request.Url.AbsoluteUri, FILE_QUERY_VAR, HttpUtility.UrlEncode(Path.GetFileName(fileName)));
            default:
                return String.Empty;
        }
    }

    private static FileResponse CreateFileResponse(HttpRequest request, string fileName, long size, string error)
    {
        return new FileResponse()
        {
            name = Path.GetFileName(fileName),
            size = size,
            type = String.Empty,
            url = CreateFileUrl(request, fileName, FILES_DISPOSITION),
            error = error,
            deleteUrl = CreateFileUrl(request, fileName, FilesDisposition.Absolute),
            deleteType = HttpMethods.DELETE
        };
    }

    private static void SerializeUploaderResponse(HttpResponse response, List<FileResponse> fileResponses)
    {

        var Serializer = new global::System.Runtime.Serialization.Json.DataContractJsonSerializer(typeof(UploaderResponse));

        Serializer.WriteObject(response.OutputStream, new UploaderResponse(fileResponses.ToArray()));
    }

    private static void FromStreamToStream(Stream source, Stream destination)
    {
        int BufferSize = source.Length >= BUFFER_SIZE ? BUFFER_SIZE : (int)source.Length;
        long BytesLeft = source.Length;

        byte[] Buffer = new byte[BufferSize];

        int BytesRead = 0;

        while (BytesLeft > 0)
        {
            BytesRead = source.Read(Buffer, 0, BytesLeft > BufferSize ? BufferSize : (int)BytesLeft);

            destination.Write(Buffer, 0, BytesRead);

            BytesLeft -= BytesRead;
        }
    }    
    
    #region IHttpAsyncHandler

    private ProcessRequestDelegate RequestDelegate;
    private delegate void ProcessRequestDelegate(HttpContext context);
    
    public IAsyncResult BeginProcessRequest(HttpContext context, AsyncCallback cb, object extraData)
    {
        RequestDelegate = new ProcessRequestDelegate(ProcessRequest);
        
        return RequestDelegate.BeginInvoke(context, cb, extraData);
    }

    public void EndProcessRequest(IAsyncResult result)
    {
        RequestDelegate.EndInvoke(result);
    }

    public bool IsReusable
    {
        get { return false; }
    }

    public void ProcessRequest(HttpContext context)
    {
        string FilesPath;

        switch (FILES_DISPOSITION)
        {
            case FilesDisposition.ServerRoot:
                FilesPath = context.Server.MapPath(FILES_PATH);
                break;
            case FilesDisposition.HandlerRoot:
                FilesPath = context.Server.MapPath(Path.GetDirectoryName(context.Request.CurrentExecutionFilePath) + FILES_PATH);
                break;
            case FilesDisposition.Absolute:
                FilesPath = FILES_PATH;
                break;
            default:
                context.Response.StatusCode = 500;
                context.Response.StatusDescription = "Configuration error (FILES_DISPOSITION)";
                return;
        }

        // prepare directory
        if (!Directory.Exists(FilesPath))
        {
            Directory.CreateDirectory(FilesPath);
        }


        string QueryFileName = context.Request[FILE_QUERY_VAR];
        string FullFileName = null;
        string ShortFileName = null;

        //if (!String.IsNullOrEmpty(QueryFileName))
        if (QueryFileName != null) // param specified, but maybe in wrong format (empty). else user will download json with listed files
        {
            ShortFileName = HttpUtility.UrlDecode(QueryFileName);
            FullFileName = String.Format(@"{0}\{1}", FilesPath, ShortFileName);

            if (QueryFileName.Trim().Length == 0 || !File.Exists(FullFileName))
            {
                context.Response.StatusCode = 404;
                context.Response.StatusDescription = "File not found";

                context.Response.End();
                return;
            }
        }

        if (context.Request.HttpMethod.ToUpper() == HttpMethods.GET)
        {
            if (FullFileName != null)
            {
                context.Response.ContentType = FILE_GET_CONTENT_TYPE;                   // http://www.digiblog.de/2011/04/android-and-the-download-file-headers/ :)
                context.Response.AddHeader("Content-Disposition", String.Format("attachment; filename={0}{1}", Path.GetFileNameWithoutExtension(ShortFileName), Path.GetExtension(ShortFileName).ToUpper()));

                using (FileStream FileReader = new FileStream(FullFileName, FileMode.Open, FileAccess.Read))
                {
                    FromStreamToStream(FileReader, context.Response.OutputStream);

                    context.Response.OutputStream.Close();
                }

                context.Response.End();
                return;
            }
            else
            {
                List<FileResponse> FileResponseList = new List<FileResponse>();

                string[] FileNames = Directory.GetFiles(FilesPath);

                foreach (string FileName in FileNames)
                {
                    FileResponseList.Add(CreateFileResponse(context.Request, FileName, new FileInfo(FileName).Length, String.Empty));
                }

                SerializeUploaderResponse(context.Response, FileResponseList);
            }
        }
        else if (context.Request.HttpMethod.ToUpper() == HttpMethods.POST)
        {
            List<FileResponse> FileResponseList = new List<FileResponse>();

            for (int FileIndex = 0; FileIndex < context.Request.Files.Count; FileIndex++)
            {
                HttpPostedFile File = context.Request.Files[FileIndex];

                string FileName = String.Format(@"{0}\{1}", FilesPath, Path.GetFileName(File.FileName));
                string ErrorMessage = String.Empty;

                for (int Attempts = 0; Attempts < ATTEMPTS_TO_WRITE; Attempts++)
                {
                    ErrorMessage = String.Empty;

                    if (System.IO.File.Exists(FileName))
                    {
                        FileName = String.Format(@"{0}\{1}_{2:yyyyMMddHHmmss.fff}{3}", FilesPath, Path.GetFileNameWithoutExtension(FileName), DateTime.Now, Path.GetExtension(FileName));
                    }

                    try
                    {
                        using (Stream FileStreamWriter = new FileStream(FileName, FileMode.CreateNew, FileAccess.Write))
                        {
                            FromStreamToStream(context.Request.InputStream, FileStreamWriter);
                        }
                    }
                    catch (Exception exception)
                    {
                        ErrorMessage = exception.Message;
                        System.Threading.Thread.Sleep(ATTEMPT_WAIT);
                        continue;
                    }

                    break;
                }

                FileResponseList.Add(CreateFileResponse(context.Request, File.FileName, File.ContentLength, ErrorMessage));
            }

            SerializeUploaderResponse(context.Response, FileResponseList);
        }
        else if (context.Request.HttpMethod.ToUpper() == HttpMethods.DELETE)
        {
            bool SuccessfullyDeleted = true;

            try
            {
                File.Delete(FullFileName);
            }
            catch
            {
                SuccessfullyDeleted = false;
            }

            context.Response.Write(String.Format("{{\"{0}\":{1}}}", ShortFileName, SuccessfullyDeleted.ToString().ToLower()));
        }
        else
        {
            context.Response.StatusCode = 405;
            context.Response.StatusDescription = "Method not allowed";
            context.Response.End();

            return;
        }


        context.Response.End();
    }

    #endregion    
    
}