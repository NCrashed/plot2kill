/**This file contains the GTK-specific parts of Plot2Kill and is publicly
 * imported by plot2kill.figure if compiled with -version=gtk.  This is even
 * more a work in progress than the DFL version.
 *
 * BUGS:
 *
 * 1.  Text word wrap doesn't work yet because the gtkD text drawing API is
 *     missing some functionality.
 *
 * 2.  HeatMap is beyond slow.
 *
 *
 * Copyright (C) 2010 David Simcha
 *
 * License:
 *
 * Boost Software License - Version 1.0 - August 17th, 2003
 *
 * Permission is hereby granted, free of charge, to any person or organization
 * obtaining a copy of the software and accompanying documentation covered by
 * this license (the "Software") to use, reproduce, display, distribute,
 * execute, and transmit the Software, and to prepare derivative works of the
 * Software, and to permit third-parties to whom the Software is furnished to
 * do so, all subject to the following:
 *
 * The copyright notices in the Software and this entire statement, including
 * the above license grant, this restriction and the following disclaimer,
 * must be included in all copies of the Software, in whole or in part, and
 * all derivative works of the Software, unless such copies or derivative
 * works are solely in the form of machine-executable object code generated by
 * a source language processor.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT
 * SHALL THE COPYRIGHT HOLDERS OR ANYONE DISTRIBUTING THE SOFTWARE BE LIABLE
 * FOR ANY DAMAGES OR OTHER LIABILITY, WHETHER IN CONTRACT, TORT OR OTHERWISE,
 * ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */
module plot2kill.gtkwrapper;

version(gtk) {

import plot2kill.util;

import gdk.Color, gdk.GC, gtk.Widget, gdk.Drawable, gtk.DrawingArea,
    gtk.MainWindow, gtk.Main, gdk.Window, gtk.Container, gtk.Window,
    gdk.Pixbuf, gdk.Pixmap, gtkc.all, gtk.FileChooserDialog, gtk.Dialog,
    gtk.FileFilter, gobject.ObjectG, cairo.Context, cairo.FontFace,
    gtkc.cairotypes, cairo.PdfSurface, cairo.SvgSurface,
    cairo.PostScriptSurface, cairo.Surface, cairo.ImageSurface;

/**GTK's implementation of a color object.*/
struct Color {
    ubyte r;
    ubyte g;
    ubyte b;
}

/**Holds context for drawing lines.*/
struct Pen {
    Color color;
    double lineWidth;
}

/**Holds context for drawing rectangles.*/
struct Brush {
    Color color;
}

///
struct Point {
    ///
    int x;

    ///
    int y;
}

///
struct Rect {
    ///
    int x;

    ///
    int y;

    ///
    int width;

    ///
    int height;
}

///
struct Size {
    ///
    int width;

    ///
    int height;
}

/**Holds font information.*/
alias cairo.FontFace.FontFace font;

/**Get a color in a GUI framework-agnostic way.*/
Color getColor(ubyte red, ubyte green, ubyte blue) {
    return Color(red, green, blue);
}

/**Get a font in a GUI framework-agnostic way.*/
struct Font {
    FontFace face;
    double size;
}

Font getFont(string fontName, double size) {
    return Font(
        Context.toyFontFaceCreate(
            fontName,
            cairo_font_slant_t.NORMAL,
            cairo_font_weight_t.NORMAL
        ), size
    );
}


///
enum TextAlignment {
    ///
    Left = 0,

    ///
    Center = 1,

    ///
    Right = 2
}

// This calls the relevant lib's method of cleaning up the given object, if
// any.
void doneWith(T)(T garbage) {
    static if(is(T : gdk.GC.GC) || is(T : gdk.Pixmap.Pixmap) ||
              is(T : gdk.Pixbuf.Pixbuf)) {
        // Most things seem to manage themselves fine, but these objects
        // leak like a seive.
        garbage.unref();

        // Since we're already in here be dragons territory, we may as well:
        core.memory.GC.free(cast(void*) garbage);
    } else static if(is(T : cairo.Context.Context) || is(T : cairo.Surface.Surface)) {

        static if(is(T : cairo.Surface.Surface)) {
            garbage.finish();
        }
        garbage.destroy();
    }
}

/**The base class for both FigureBase and Subplot.  Holds common functionality
 * like saving and text drawing.
 */
abstract class FigureBase {
    mixin(GuiAgnosticBaseMixin);

private:
    enum ubyteMax = cast(double) ubyte.max;

    // See drawLine() for an explanation of these variables.
    PlotPoint[2] lastLine;
    Pen lastLinePen;

    void saveImplPixmap
    (string filename, string type, double width, double height) {
        int w = roundTo!int(width);
        int h = roundTo!int(height);

        auto pixmap = new Pixmap(null, w, h, 24);
        scope(exit) doneWith(pixmap);

        auto c = new Context(pixmap);
        scope(exit) doneWith(c);

        this.drawTo(c, PlotRect(0, 0, w, h));
        auto pixbuf = new Pixbuf(pixmap, 0, 0, w, h);
        scope(exit) doneWith(pixbuf);

        pixbuf.savev(filename, type, null, null);
    }

    void saveImplSurface
    (string filename, string type, double width, double height) {
        Surface surf;
        switch(type) {
            case "pdf":
                surf = PdfSurface.create(filename, width, height);
                break;
            case "eps":
                surf = PostScriptSurface.create(filename, width, height);
                break;
            case "svg":
                surf = SvgSurface.create(filename, width, height);
                break;
            case "png":
                surf = ImageSurface.create(cairo_format_t.RGB24,
                    roundTo!int(width), roundTo!int(height));
                break;
            default:
                enforce(0, "Invalid file format:  " ~ type);
        }

        scope(exit) doneWith(surf);
        auto context = Context.create(surf);
        scope(exit) doneWith(context);

        this.drawTo(context, PlotRect(0,0, width, height));
        surf.flush();

        if(type == "png") {
            // So sue me for the cast.
            auto result = (cast(ImageSurface) surf).writeToPng(filename);
            enforce(result == cairo_status_t.SUCCESS, text(
                "Unsuccessfully wrote png.  Error:  ", result));
        }

    }

protected:
    // GTK reports the usable area as the size of the window, so these are 0.
    enum horizontalBorderWidth = 0;
    enum verticalBorderWidth = 0;

    Context context;

public:
    // These are undocumented FOR A REASON:  They aren't part of the public
    // API, but package is so broken it's not usable.  All this stuff w/o
    // ddoc should only be messed with if you're a developer of this lib,
    // not if you want to use it as a black box.

    final void drawLine
    (Pen pen, double startX, double startY, double endX, double endY) {
        /* HACK ALERT:  The front end to this library is designed for each line
         * to be drawn as a discrete unit, but for line joining purposes,
         * lines need to be drawn in a single path in Cairo.  Therefore,
         * we save the last line drawn and draw it again if its end coincides
         * with the current line's beginning.
         */
        context.save();
        scope(exit) context.restore();
        context.newPath();

        auto c = pen.color;
        context.setSourceRgb(c.r / ubyteMax, c.g / ubyteMax, c.b / ubyteMax);
        context.setLineWidth(pen.lineWidth);

        if(lastLine[1] == PlotPoint(startX, startY) && lastLinePen == pen) {
            // Redraw the last line.
            context.moveTo(lastLine[0].x + xOffset, lastLine[0].y + yOffset);
            context.lineTo(lastLine[1].x + xOffset, lastLine[1].y + yOffset);
        } else {
            context.moveTo(startX + xOffset, startY + yOffset);
        }

        lastLine[0] = PlotPoint(startX, startY);
        lastLine[1] = PlotPoint(endX, endY);
        lastLinePen = pen;

        context.lineTo(endX + xOffset, endY + yOffset);
        context.stroke();
    }

    final void drawLine(Pen pen, PlotPoint start, PlotPoint end) {
        this.drawLine(pen, start.x, start.y, end.x, end.y);
    }

    final void drawRectangle
    (Pen pen, double x, double y, double width, double height) {
        context.save();
        scope(exit) context.restore();
        context.newPath();

        auto c = pen.color;
        context.setSourceRgb(c.r / ubyteMax, c.g / ubyteMax, c.b / ubyteMax);
        context.setLineWidth(pen.lineWidth);
        context.rectangle(x + xOffset, y + yOffset, width, height);
        context.stroke();
    }

    final void drawRectangle(Pen pen, Rect r) {
        this.drawRectangle(pen, r.x, r.y, width, height);
    }

    final void fillRectangle
    (Brush brush, double x, double y, double width, double height) {
        context.save();
        scope(exit) context.restore();
        context.newPath();

        auto c = brush.color;
        enum ubyteMax = cast(double) ubyte.max;
        context.setSourceRgb(c.r / ubyteMax, c.g / ubyteMax, c.b / ubyteMax);
        context.rectangle(x + xOffset, y + yOffset, width, height);
        context.fill();
    }

    final void fillRectangle(Brush brush, Rect r) {
        this.fillRectangle(brush, r.x, r.y, r.width, r.height);
    }

    final void drawText(
        string text,
        Font font,
        Color pointColor,
        PlotRect rect,
        TextAlignment alignment
    ) {
        context.save();
        scope(exit) context.restore();
        context.newPath();

        drawTextCurrentContext(text, font, pointColor, rect, alignment);
    }

    final void drawTextCurrentContext(
        string text,
        Font font,
        Color pointColor,
        PlotRect rect,
        TextAlignment alignment
    ) {
        alias rect r;  // save typing
        auto measurements = measureText(text, font);
        if(measurements.width > rect.width) {
            alignment = TextAlignment.Left;
        }

        if(alignment == TextAlignment.Left) {
            r = PlotRect(
                r.x,
                r.y + measurements.height,
                r.width,
                r.height
            );
        } else if(alignment == TextAlignment.Center) {
            r = PlotRect(
                r.x + (r.width - measurements.width) / 2,
                r.y + measurements.height,
                r.width, r.height
            );
        } else if(alignment == TextAlignment.Right) {
            r = PlotRect(
                r.x + (r.width - measurements.width),
                r.y + measurements.height,
                r.width, r.height
            );
        } else {
            assert(0);
        }

        //context.rectangle(r.x, r.y - measurements.height, r.width, r.height);
        //context.clip();
        context.setFontSize(font.size);
        context.setFontFace(font.face);

        alias pointColor c;
        context.setSourceRgb(c.r / ubyteMax, c.g / ubyteMax, c.b / ubyteMax);

        context.setLineWidth(0.5);
        context.moveTo(r.x + xOffset, r.y + yOffset);
        context.textPath(text);
        context.fill();
    }

    final void drawText(
        string text,
        Font font,
        Color pointColor,
        PlotRect rect
    ) {
        drawText(text, font, pointColor, rect, TextAlignment.Left);
    }

    final void drawRotatedText(
        string text,
        Font font,
        Color pointColor,
        PlotRect rect,
        TextAlignment alignment
    ) {
        context.save();
        scope(exit) context.restore;
        context.newPath();

        alias rect r;  // save typing
        auto measurements = measureText(text, font);
        immutable slack  = rect.height - measurements.width;
        if(slack < 0) {
            alignment = TextAlignment.Left;
        }

        if(alignment == TextAlignment.Left) {
            r = PlotRect(
                r.x + r.width,
                r.y + r.height,
                r.width,
                r.height
            );
        } else if(alignment == TextAlignment.Center) {
            r = PlotRect(
                r.x + r.width,
                r.y + r.height - slack / 2,
                r.width, r.height
            );
        } else if(alignment == TextAlignment.Right) {
            r = PlotRect(
                r.x + r.width,
                r.y + r.height - slack,
                r.width, r.height
            );
        } else {
            assert(0);
        }
        //context.rectangle(r.x, r.y - measurements.height, r.width, r.height);
        //context.clip();
        context.setFontSize(font.size);
        context.setFontFace(font.face);

        alias pointColor c;
        context.setSourceRgb(c.r / ubyteMax, c.g / ubyteMax, c.b / ubyteMax);

        context.setLineWidth(0.5);
        context.moveTo(r.x + xOffset, r.y + yOffset);
        context.rotate(PI * 1.5);
        context.textPath(text);
        context.fill();
    }

    final void drawRotatedText(
        string text,
        Font font,
        Color pointColor,
        PlotRect rect
    ) {
        drawRotatedText(text, font, pointColor, rect, TextAlignment.Left);
    }

    // BUGS:  Ignores maxWidth.
    final PlotSize measureText
    (string text, Font font, double maxWidth, TextAlignment alignment) {
        return measureText(text, font);
    }

    // BUGS:  Ignores maxWidth.
    final PlotSize measureText(string text, Font font, double maxWidth) {
        return measureText(text, font);

    }

    final PlotSize measureText(string text, Font font) {
        context.save();
        scope(exit) context.restore();

        context.setLineWidth(1);
        context.setFontSize(font.size);
        context.setFontFace(font.face);
        cairo_text_extents_t ext;

        context.textExtents(text, &ext);
        return PlotSize(ext.width, ext.height);
    }

    // TODO:  Add support for stuff other than solid brushes.
    /*Get a brush in a GUI framework-agnostic way.*/
    static Brush getBrush(Color color) {
        return Brush(color);
    }

    /*Get a pen in a GUI framework-agnostic way.*/
    static Pen getPen(Color color, int width = 1) {
        return Pen(color, width);
    }

    final double width()  {
        return _width;
    }

    final double height()  {
        return _height;
    }

    abstract void drawImpl() {}

    void drawTo(Context context) {
        drawTo(context, this.width, this.height);
    }

    void drawTo(Context context, double width, double height) {
        return drawTo(context, PlotRect(0, 0, width, height));
    }

    // Allows drawing at an offset from the origin.
    void drawTo(Context context, PlotRect whereToDraw) {
        // Save the default class-level values, make the values passed in the
        // class-level values, call drawImpl(), then restore the default values.
        auto oldContext = this.context;
        auto oldWidth = this._width;
        auto oldHeight = this._height;
        auto oldXoffset = this.xOffset;
        auto oldYoffset = this.yOffset;

        scope(exit) {
            this.context = oldContext;
            this._height = oldHeight;
            this._width = oldWidth;
            this.xOffset = oldXoffset;
            this.yOffset = oldYoffset;
        }

        this.context = context;
        this._width = whereToDraw.width;
        this._height = whereToDraw.height;
        this.xOffset = whereToDraw.x;
        this.yOffset = whereToDraw.y;
        drawImpl();
    }

    abstract int defaultWindowWidth();
    abstract int defaultWindowHeight();
    abstract int minWindowWidth();
    abstract int minWindowHeight();


    /**Saves this figure to a file.  The file type can be one of either the
     * raster formats .png, .jpg, .tiff, and .bmp, or the vector formats
     * .pdf, .svg and .eps.  The width and height parameters allow you to
     * specify explicit width and height parameters for the image file.  If
     * width and height are left at their default values
     * of 0, the default width and height of the subclass being saved will
     * be used.
     *
     * Bugs:  .jpg, .tiff and .bmp formats rely on Pixmap objects, meaning
     *        you can't save them to a file unless you have a screen and
     *        have called Main.init(), even though saving should have
     *        nothing to do with X or screens.
     */
    void saveToFile
    (string filename, string type, double width = 0, double height = 0) {
        if(width == 0 || height == 0) {
            width = this.defaultWindowWidth;
            height = this.defaultWindowHeight;
        }

        if(type == "eps" || type == "pdf" || type == "svg" || type == "png") {
            return saveImplSurface(filename, type, width, height);
        } else {
            enforce(type == "tiff" || type == "bmp" || type == "jpg",
                "Invalid format:  " ~ type);
            return saveImplPixmap(filename, type, width, height);
        }
    }

    /**Convenience function that infers the type from the filename extenstion
     * and defaults to .png if no valid file format extension is found.
     */
    void saveToFile(string filename, double width = 0, double height = 0) {
        auto dotIndex = std.string.lastIndexOf(filename, '.');
        string type;
        if(dotIndex == filename.length - 1 || dotIndex == -1) {
            type = "png";
        } else {
            type = filename[dotIndex + 1..$];
        }

        try {
            saveToFile(filename, type, width, height);
        } catch {
            // Default to svg.
            saveToFile(filename, "png", width, height);
        }
    }

    /**Creates a Widget that will have this object drawn to it.  This Widget
     * can be displayed in a window.
     */
    FigureWidget toWidget() {
        return new FigureWidget(this);
    }

    /**Draw and display the figure as a main form.  This is useful in
     * otherwise console-based apps that want to display a few plots.
     * However, you can't have another main form up at the same time.
     */
    void showAsMain() {
        auto mw = new DefaultPlotWindow!(MainWindow)(this.toWidget);
        Main.run();
    }

    /**Returns a default plot window with this figure in it.*/
    gtk.Window.Window getDefaultWindow() {
        return new DefaultPlotWindow!(gtk.Window.Window)(this.toWidget);
    }
}


/**The default widget for displaying Figure and Subplot objects on screen.
 * This class has no public constructor or static factory method because the
 * proper way to instantiate this object is via the toWidget properties
 * of FigureBase and Subplot.
 */
class FigureWidget : DrawingArea {
private:
    FigureBase _figure;

package:
    this(FigureBase fig) {
        super();
        this._figure = fig;
        this.addOnExpose(&onDrawingExpose);
        this.setSizeRequest(fig.minWindowWidth, fig.minWindowHeight);
    }

    bool onDrawingExpose(GdkEventExpose* event, Widget drawingArea) {
        draw();
        return true;
    }

    void draw(double w, double h) {
        enforce(getParent() !is null, this.classinfo.name);
        auto context = new Context(getWindow());
        scope(exit) doneWith(context);

        figure.drawTo(context, w, h);
    }

public:
    /**Get the underlying FigureBase object.*/
    final FigureBase figure() @property {
        return _figure;
    }

    /**If set as an addOnSizeAllocate callback, this will resize this control
     * to the size of its parent window when the parent window is resized.
     */
    void parentSizeChanged(GtkAllocation* alloc, Widget widget) {
        if(this.getWidth != alloc.width || this.getHeight != alloc.height) {
            this.setSizeRequest(alloc.width, alloc.height);
        }
    }

    /**Draw the figure to the internal drawing area.*/
    final void draw() {
        draw(this.getWidth, this.getHeight);
    }

}

/**Default plot window.  It's a subclass of either Window or MainWindow
 * depending on the template parameter.
 */
template DefaultPlotWindow(Base)
if(is(Base == gtk.Window.Window) || is(Base == gtk.MainWindow.MainWindow)) {

    ///
    class DefaultPlotWindow : Base {
    private:
        FigureWidget widget;

        immutable string[7] saveTypes =
            ["*.png", "*.bmp", "*.tiff", "*.jpeg", "*.eps", "*.pdf", "*.svg"];

        // Based on using print statements to figure it out.  If anyone can
        // find the right documentation and wants to convert this to a proper
        // enum, feel free.
        enum rightClick = 3;


        void saveDialogResponse(int response, Dialog d) {
            auto fc = cast(FileChooserDialog) d;
            assert(fc);

            if(response == GtkResponseType.GTK_RESPONSE_OK) {
                string name = fc.getFilename();
                auto fileType = fc.getFilter().getName();

                widget.figure.saveToFile
                    (name, fileType, widget.getWidth, widget.getHeight);
                d.destroy();
            } else {
                d.destroy();
            }
        }


        bool clickEvent(GdkEventButton* event, Widget widget) {
            if(event.button != rightClick) {
                return false;
            }


            auto fc = new FileChooserDialog("Save plot...", this,
               GtkFileChooserAction.SAVE);
            fc.setDoOverwriteConfirmation(1);  // Why isn't this the default?
            fc.addOnResponse(&saveDialogResponse);

            foreach(ext; saveTypes) {
                auto filter = new FileFilter();
                filter.setName(ext[2..$]);
                filter.addPattern(ext);
                fc.addFilter(filter);
            }

            fc.run();
            return true;
        }

    public:
        ///
        this(FigureWidget widget) {
            super("Plot Window.  Right-click to save plot.");
            this.widget = widget;
            this.add(widget);
            widget.setSizeRequest(
                widget.figure.defaultWindowWidth,
                widget.figure.defaultWindowHeight
            );
            this.resize(widget.getWidth, widget.getHeight);
            this.setSizeRequest(
                widget.figure.minWindowWidth,
                widget.figure.minWindowHeight
            );

            this.addOnButtonPress(&clickEvent);
            widget.addOnSizeAllocate(&widget.parentSizeChanged);
            widget.showAll();
            widget.queueDraw();
            this.showAll();
        }
    }
}

}
