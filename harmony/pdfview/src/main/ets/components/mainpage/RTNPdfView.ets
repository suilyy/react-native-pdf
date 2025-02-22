/*
 * MIT License
 *
 * Copyright (C) 2024 Huawei Device Co., Ltd.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

import { Descriptor, ComponentBuilderContext, ViewRawProps, ViewBaseProps } from '@rnoh/react-native-openharmony';
import { RNOHContext, RNViewBase } from '@rnoh/react-native-openharmony';
import { BusinessError } from '@kit.BasicServicesKit';
import fs from '@ohos.file.fs';
import request from '@ohos.request';
import buffer from '@ohos.buffer';
import cryptoFramework from '@ohos.security.cryptoFramework';
import { pdfService, pdfViewManager, PdfView } from '@kit.PDFKit'
import { common } from '@kit.AbilityKit';
import { ON_PROGRESS_CHANGE } from './types';
import Logger from '../../Logger';

export const PDF_VIEW_TYPE: string = "RTNPdfView";

export interface PdfViewState {}

interface Source {
  uri: string;
  headers?: Record<string, Object>;
  cache?: boolean;
  cacheFileName?: string;
  expiration?: number;
  method?: string;
};

export interface PdfViewRawProps extends ViewRawProps {
  source: Source,
  path?: string,
  page?: number,
  scale?: number,
  minScale?: number,
  maxScale?: number,
  horizontal?: boolean,
  enablePaging?: boolean,
  enableRTL?: boolean,
  enableAnnotationRendering?: boolean,
  showsHorizontalScrollIndicator?: boolean,
  showsVerticalScrollIndicator?: boolean,
  enableAntialiasing?: boolean,
  fitPolicy?: number,
  spacing?: number,
  password?: string,
  singlePage?: boolean,
}

export type PdfViewDescriptor = Descriptor<'RTNPdfView', ViewBaseProps, PdfViewState, PdfViewRawProps>

@Component
export struct RTNPdfView {
  ctx!: RNOHContext;
  tag: number = 0;
  @BuilderParam buildCustomComponent: (componentBuilderContext: ComponentBuilderContext) => void = this.emptyBuild;
  @State descriptor: PdfViewDescriptor = Object() as PdfViewDescriptor;
  @State pageIndex: number = 1;
  @State controllerStatus: boolean = false;
  @State pdfUrl: string = "";
  private unregisterDescriptorChangesListener?: () => void = undefined;
  private cleanupCommandCallback?: () => void = undefined;
  private pdfController: pdfViewManager.PdfController = new pdfViewManager.PdfController();

  @Builder
  emptyBuild(ctx: ComponentBuilderContext) {
  }

  async doLoadHttpDocument(path: string): Promise<void> {
    Logger.debug(`[RTNPdfView]: doLoadHttpDocument, path is ${path}`);
    try {
      const filePath: string = await this.downloadHttpFile(path);
      Logger.debug(`[RTNPdfView]: doLoadHttpDocument, filePath is ${filePath}`);
      this.doLoadLocalDocument(filePath, !this.descriptor.rawProps.source?.cache);
    } catch (e) {
      Logger.error(`[RTNPdfView]: fs accessSync: ${e}`);
      this.onError(`[RTNPdfView]: fs accessSync: ${e}`);
    }
  }

  doLoadLocalDocument(filePath: string, isDelOriginFile: boolean = true): void {
    let initPageIndex: number | undefined = this.descriptor.rawProps.page;
    let spacing: number = Number(this.descriptor.rawProps.spacing);
    let scale: number =  Number(this.descriptor.rawProps.scale);
    let minScale: number | undefined = this.descriptor.rawProps.minScale;
    let maxScale: number | undefined = this.descriptor.rawProps.maxScale;
    let password: string | undefined = this.descriptor.rawProps.password;
    let fitPolicy: number | undefined = this.descriptor.rawProps.fitPolicy;

    Logger.debug(`[RTNPdfView]: doLoadLocalDocument, filePath is ${filePath}, isDelOriginFile is ${isDelOriginFile}`);
    const progressCallBack: (progress: number) => number = (progress: number) => {
      Logger.debug(`[RTNPdfView]: proress is ${(progress / 100).toFixed(2)}`);
      this.loadProgress(Number((progress / 100).toFixed(2)));
      return 0;
    };

    if (filePath) {
      this.pdfController.releaseDocument();
      this.pdfController.loadDocument(filePath, password, initPageIndex, progressCallBack)
        .then((res: pdfService.ParseResult) => {
          switch (res) {
            case pdfService.ParseResult.PARSE_SUCCESS:
              this.pdfController.setPageSpacing(spacing, spacing); //由于rn侧值传递一个参数，故此处默认为连续滚动模式。设置上下面的间距。
              this.pdfController.setPageZoom(scale);
              const pageCount: number = this.pdfController.getPageCount();
              if (typeof fitPolicy === 'number') {
                if (fitPolicy === 0) {
                  this.pdfController.setPageFit(pdfService.PageFit.FIT_WIDTH);
                } else if (fitPolicy === 1) {
                  this.pdfController.setPageFit(pdfService.PageFit.FIT_HEIGHT);
                } else if (fitPolicy === 2) {
                  this.pdfController.setPageFit(pdfService.PageFit.FIT_PAGE);
                }
              }

              // 注册监听器
              let tempScale: number | undefined = scale;
              this.pdfController.registerScaleChangedListener((currentScale: number) => {
                if (tempScale !== currentScale) {
                  if (typeof maxScale === 'number' && currentScale > maxScale) {
                    this.pdfController.setPageZoom(maxScale);
                  } else if (typeof minScale === 'number' && currentScale < minScale) {
                    this.pdfController.setPageZoom(minScale);
                  }
                  tempScale = currentScale;
                }
                this.onScaleChanged(currentScale);
              });
              this.pdfController.registerPageChangedListener((pageIndex: number) => {
                this.onPageChanged((pageIndex + 1), pageCount);
              });
              this.pdfController.registerActionClickListener((redirectInfo: pdfViewManager.RedirectInfo) => {
                this.onPressLink(redirectInfo.content);
              });
              this.loadComplete(pageCount, filePath,);
              Logger.debug(`[RTNPdfView]: loadDocument success`);
              break;
            case pdfService.ParseResult.PARSE_ERROR_FILE:
              this.onError('loadDocument error: PARSE_ERROR_FILE');
              break;
            case pdfService.ParseResult.PARSE_ERROR_FORMAT:
              this.onError('loadDocument error: PARSE_ERROR_FORMAT');
              break;
            case pdfService.ParseResult.PARSE_ERROR_PASSWORD:
              this.onError('loadDocument error: PARSE_ERROR_PASSWORD');
              break;
            case pdfService.ParseResult.PARSE_ERROR_HANDLER:
              this.onError('loadDocument error: PARSE_ERROR_HANDLER');
              break;
            case pdfService.ParseResult.PARSE_ERROR_CERT:
              this.onError('loadDocument error: PARSE_ERROR_CERT');
              break;
            default:
              this.onError('loadDocument error: UNKNOWN');
              break;
          }
        })
        .catch((e: Error) => {
          Logger.error(`[RTNPdfView]: loadDocument error: ${e}`);
          this.onError(e.message);
        })
        .finally(() => {
          Logger.debug(`[RTNPdfView]: isDelOriginFile is : ${isDelOriginFile}`);
          if (isDelOriginFile) {
            fs.unlink(filePath).then(() => {
              Logger.debug(`[RTNPdfView]: originFile deleted`);
            })
          }
        })
    }
  }

  async downloadHttpFile(url: string): Promise<string> {
    let context = getContext(this) as common.UIAbilityContext;
    let filesDir = context.filesDir;
    let res: string = "";
    const hashFileName: string = await this.processFileName(url);
    const cacheFileName = await this.checkCache(hashFileName);
    if(this.descriptor.rawProps.source?.cache && !!cacheFileName){
      res = cacheFileName;
    }else{
      if (!!cacheFileName && fs.accessSync(cacheFileName)) {
        fs.unlinkSync(cacheFileName);
      }
      const fullFileName: string = filesDir + "/" + hashFileName + new Date().getTime() + '.pdf';
      res = await this.downloadAction(context, url, fullFileName, {}, 0);
    }
    Logger.info(`[RTNPdfView]:res: ${res}`);
    return res;
  }
  async downloadAction(
    context: Context,
    url: string,
    fullFileName: string,
    distHeaders: Record<string, Object>,
    redirectCount: number = 0,
  ): Promise<string> {
    if (redirectCount > 5) {
      throw new Error("Too many redirects");
    }
    return new Promise((resolve, reject) => {
      // 获取应用文件路径
      try {
        Logger.info(`[RTNPdfView]: start downloadFile`);
        const config: request.agent.Config = {
          action: request.agent.Action.DOWNLOAD,
          url,
          method: this.descriptor.rawProps.source.method ?? 'GET',
          headers: assignHeader(this.descriptor.rawProps.source?.headers || {}, distHeaders|| {}),
          saveas: fullFileName,
          overwrite: true,
          mode: request.agent.Mode.FOREGROUND
        };
        request.agent.create(context, config).then((task: request.agent.Task) => {
          task.on('completed', () => {
            Logger.info(`[RTNPdfView]: finish downloadFile`);
            resolve(fullFileName);
          })
          task.on('failed', (progress: request.agent.Progress) => {
            console.info('[RTNPdfView]: downloadFile failed.', JSON.stringify(progress));
          });
          task.on('response', async (response: request.agent.HttpResponse) => {
            console.info('[RTNPdfView]: downloadFile response.', JSON.stringify(response));
            if (response.statusCode > 300 && response.statusCode < 400) {
              let redirectUrl: string = response.headers.get('location')?.toString() ?? '';
              let cookie: string = response.headers.get('set-cookie')?.toString() ?? '';
              task.off('progress');
              task.off('completed');
              task.off('response');
              task.stop();
              try {
                const result = await this.downloadAction(context, redirectUrl, fullFileName, { 'cookie': cookie }, redirectCount + 1);

                Logger.info(`[RTNPdfView]:result: ${result} -----count: ${redirectCount}}`);
                resolve(result)
              } catch (e) {
                reject(e);
              }
            }
          });
          task.start();
        }).catch((err: BusinessError) => {
          Logger.info(`[RTNPdfView]: error downloadHttpFile`);
          this.onError(err.message);
          reject("downloadFile failed" + err.message);
        });
      } catch (error) {
        Logger.info(`[RTNPdfView]: error downloadHttpFile`);
        let err: BusinessError = error as BusinessError;
        this.onError(err.message);
        reject("downloadFile failed" + err.message);
      }
    });
  }

  async processFileName(originalURL: string): Promise<string> {
    return new Promise(async (resolve, reject) => {
      let mdAlgName = 'SHA256'; // 摘要算法名
      let md = cryptoFramework.createMd(mdAlgName);
      try {
        await md.update({ data: new Uint8Array(buffer.from(originalURL, 'utf-8').buffer) });
        let mdResult: cryptoFramework.DataBlob = await md.digest();
        const fileName: string = buffer.from(mdResult.data).toString('hex');
        Logger.info(`[RTNPdfView]: fileName: ${fileName}`);
        resolve(fileName);
      } catch (e) {
        this.onError(e.message);
        reject("processFileName error");
      }
    });
  }
  async checkCache(hashFileName: string): Promise<string> {
    try {
      let filesDir = (getContext() as common.UIAbilityContext).filesDir;
      let cacheFileName: string = "";
      let fileList = fs.listFileSync(filesDir);
      fileList.forEach(file=>{
        let _hashFileName = file.slice(0, -17);
        _hashFileName === hashFileName && (cacheFileName = filesDir + "/" + file);
      })
      return Promise.resolve(cacheFileName);
    } catch (e) {
      this.onError(e.message);
      return Promise.reject("checkCache error");
    }
  }

  async sendToSandBox(assetPath: string): Promise<string> {
    assetPath = assetPath!.replace("asset://", "assets/");
    Logger.info(`[RTNPdfView]: load pdf assetPath: ${assetPath}`);
    const hashFileName: string = await this.processFileName(assetPath);
    const cacheFileName = await this.checkCache(hashFileName);
    let fileFullPath: string = "";

    if(this.descriptor.rawProps.source?.cache && !!cacheFileName){
      fileFullPath = cacheFileName;
    }else{
      if (!!cacheFileName && fs.accessSync(cacheFileName)) {
        fs.unlinkSync(cacheFileName);
      }
      // 需将pdf文档复制到沙箱路径下
      let context = getContext() as common.UIAbilityContext;
      let content = context.resourceManager.getRawFileContentSync(`${assetPath}`); // pdf_reference
      let dir = context.filesDir;
      fileFullPath = dir + '/' + hashFileName + new Date().getTime() + '.pdf';
      Logger.info(`[RTNPdfView]: load pdf filePath: ${fileFullPath}`);
      let res = fs.accessSync(fileFullPath);
      Logger.info(`[RTNPdfView]: fs accessSync: ${res}`);
      let fdSand = fs.openSync(fileFullPath, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(fdSand.fd, content.buffer);
      fs.closeSync(fdSand.fd);
    }

    return fileFullPath;
  }

  async updateSource() {
    let src: string | undefined = this.descriptor.rawProps.path;
    Logger.info(`[RTNPdfView]: src is ${src}`);
    if (src) {
      this.pdfUrl = src;
      if (src!.startsWith('http://') || src!.startsWith('https://')) {
        this.doLoadHttpDocument(src); // 适配加载在线文件
      } else {
        let isDeleteOriginFile: boolean = false;
        if (src!.startsWith('asset://')) { // 适配require('../assets/test.pdf')
          src = await this.sendToSandBox(src);
          isDeleteOriginFile = true;
        }
        this.doLoadLocalDocument(src, isDeleteOriginFile); // 适配本地其他目录，比如cache
      }
    }
  }

  aboutToAppear() {
    this.descriptor = this.ctx.descriptorRegistry.getDescriptor<PdfViewDescriptor>(this.tag);
    this.updateSource();
    this.unregisterDescriptorChangesListener = this.ctx.descriptorRegistry.subscribeToDescriptorChanges(this.tag,
      (newDescriptor) => {
        this.descriptor = (newDescriptor as PdfViewDescriptor)
        this.descriptor.rawProps.path !== this.pdfUrl && this.updateSource();
      }
    )
    this.cleanupCommandCallback = this.ctx.componentCommandReceiver.registerCommandCallback(
      this.tag,
      (command, args: (boolean | number)[]) => {
        Logger.info(`[RNOH]: HarmonyOS does not support,command:  ${command}, arg: ${args[0]}`);
        this.pageIndex = args[0] as number;
        this.pdfUrl = "";
      });
  }

  aboutToDisappear() {
    this.cleanupCommandCallback?.();
    this.unregisterDescriptorChangesListener?.();
  }

  loadComplete(numberOfPages: number, filePath: string) {
    Logger.info("[RNOH]:enter loadComplete");

    // 获取页面宽度、高度
    this.ctx.rnInstance.emitComponentEvent(
      this.descriptor.tag,
      PDF_VIEW_TYPE,
      {
        type: 'onChange',
        message: `loadComplete|${numberOfPages}|100|100`
      }
    );
  }

  loadProgress(percent: number) {
    Logger.info("[RNOH]:enter loadProgress");
    this.ctx.rnInstance.emitComponentEvent(
      this.descriptor.tag,
      PDF_VIEW_TYPE,
      {
        type: 'onChange',
        message: `loadProgress|${percent}`
      }
    );
  }

  onError(e: string) {
    Logger.info("[RNOH]:enter onError");
    this.ctx.rnInstance.emitComponentEvent(
      this.descriptor.tag,
      PDF_VIEW_TYPE,
      {
        type: 'onChange',
        message: `error|${e}`
      }
    );
  }

  onPageChanged(page: number, numberOfPages: number) {
    Logger.info("[RNOH]:enter pageChanged");
    this.ctx.rnInstance.emitComponentEvent(
      this.descriptor.tag,
      PDF_VIEW_TYPE,
      {
        type: 'onChange',
        message: `pageChanged|${page}|${numberOfPages}`
      }
    );
  }

  onPressLink(url: string) {
    Logger.info("[RNOH]:enter onPressLink");
    this.ctx.rnInstance.emitComponentEvent(
      this.descriptor.tag,
      PDF_VIEW_TYPE,
      {
        type: 'onChange',
        message: `linkPressed|${url}`
      }
    );
  }

  onScaleChanged(currentScale: number) {
    Logger.info("[RNOH]:enter scaleChanged");
    this.ctx.rnInstance.emitComponentEvent(
      this.descriptor.tag,
      PDF_VIEW_TYPE,
      {
        type: 'onChange',
        message: `scaleChanged|${currentScale}`
      }
    );
  }

  onChange() {
    Logger.info("[RNOH]:onChange not support");
    this.ctx.rnInstance.emitComponentEvent(
      this.descriptor.tag,
      PDF_VIEW_TYPE,
      {
        type: 'onChange',
        message: ON_PROGRESS_CHANGE
      }
    );
  }

  build() {
    RNViewBase({ ctx: this.ctx, tag: this.tag }) {
      if (this.descriptor.rawProps.path) {
        PdfView(
          {
            controller: this.pdfController,
            pageLayout: pdfService.PageLayout.LAYOUT_SINGLE,
            isContinuous: true,
            pageFit: pdfService.PageFit.FIT_WIDTH
          }
        )
      }
    }
  }
}
function assignHeader(target: Record<string, Object>, ...source: Record<string, Object>[]): Record<string, Object> {
  for(let s of source){
    for(let k of Object.keys(s)){
      target[k] = Reflect.get(s, k)
    }
  }
  return target
}